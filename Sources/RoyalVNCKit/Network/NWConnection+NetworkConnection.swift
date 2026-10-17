#if canImport(Network)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import Network

extension NWConnection: NetworkConnection {
    convenience init(settings: NetworkConnectionSettings) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = settings.connectionTimeout

        // A server may send nothing while its screen is still; keepalive is
        // how a viewer notices one that has gone away (TCPKeepalive). In
        // seconds.
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = Int(TCPKeepalive.idleSeconds)
        tcpOptions.keepaliveInterval = Int(TCPKeepalive.intervalSeconds)
        tcpOptions.keepaliveCount = Int(TCPKeepalive.probeCount)

        let connectionParameters = NWParameters(tls: nil,
                                                tcp: tcpOptions)

        connectionParameters.expiredDNSBehavior = .allow
        connectionParameters.serviceClass = .interactiveVideo

        self.init(host: .init(settings.host),
                  port: .init(rawValue: settings.port)!,
                  using: connectionParameters)
    }

    /// Whether a `.waiting` reason is an answer rather than a delay.
    ///
    /// `NWConnection` uses `.waiting` for two different situations and the
    /// difference decides whether a connection should give up. A refusal is an
    /// answer: something replied and retrying gets the same reply. Anything else
    /// -- no usable path yet, and in particular a Local Network permission the
    /// user has not answered -- clears on its own if given a moment.
    ///
    /// Measured on macOS: a closed port on loopback reports
    /// `.waiting(ECONNREFUSED)` at 0.00s and stays there while it retries, so
    /// the refusal case has to be recognised here or a mistyped port waits out
    /// the whole connection timeout.
    ///
    /// The classification lives in this file because this is where Network is
    /// imported; above it, `NetworkConnectionStatus` carries a plain `Error` and
    /// cannot tell the two apart.
    static func isAnAnswer(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .ECONNRESET, .ENETDOWN:
                return true

            default:
                // EPERM and EHOSTUNREACH land here deliberately: an unanswered
                // Local Network prompt looks like both, and it clears the
                // moment the user taps Allow.
                return false
            }

        case .dns:
            // A name that does not resolve is an answer too, and it arrives as
            // `.dns` rather than `.posix` -- which is how a mistyped host name
            // slipped through the first version of this and waited out the full
            // deadline. Caught by the resolver test in RepeaterEndToEndTests.
            return true

        default:
            return false
        }
    }

    var status: NetworkConnectionStatus {
        switch state {
        case .setup: .setup

        // A definitive `.waiting` is reported upwards as the failure it is, so
        // that the layer above can treat every remaining `.waiting` as "not
        // yet" and wait for it.
        case .waiting(let error):
            Self.isAnAnswer(error) ? .failed(error) : .waiting(error)
        case .preparing: .preparing
        case .ready: .ready
        case .failed(let error): .failed(error)
        case .cancelled: .cancelled

        @unknown default:
            .unknown(self)
        }
    }

    func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
        guard let statusUpdateHandler else {
            stateUpdateHandler = nil

            return
        }

        stateUpdateHandler = { state in
            switch state {
            case .setup:
                statusUpdateHandler(.setup)
            case .waiting(let error):
                // Same split as `status` above: a refusal is reported as the
                // failure it is, everything else as "not yet".
                statusUpdateHandler(Self.isAnAnswer(error) ? .failed(error)
                                                           : .waiting(error))
            case .preparing:
                statusUpdateHandler(.preparing)
            case .ready:
                statusUpdateHandler(.ready)
            case .failed(let error):
                statusUpdateHandler(.failed(error))
            case .cancelled:
                statusUpdateHandler(.cancelled)

            @unknown default:
                statusUpdateHandler(.unknown(self))
            }
        }
    }

    var isReady: Bool {
        state == .ready
    }
}

extension NWConnection: NetworkConnectionReading {
	/// A read with nothing kept between reads: after a completion that brought the last bytes and
	/// the end together, the next read reports what Network.framework says then (see `ReceiveEnd`),
	/// not the close. `NWConnectionTransport`, the kit's one reader of an NWConnection, keeps a
	/// `ReceiveEnd` for its connection's life.
	func read(minimumLength: Int,
              maximumLength: Int) async throws -> Data {
		try await read(minimumLength: minimumLength,
					   maximumLength: maximumLength,
					   keepingEndIn: ReceiveEnd())
	}

	/// One receive, as a read: the bytes it brought, with the end of the stream -- the peer's close,
	/// or the error that ended it -- kept in `end` for the next read when it came with them.
	///
	/// The bytes first, whatever else the completion says. Network.framework can deliver a stream's
	/// last bytes in the same completion that marks it complete, or that carries the error ending it.
	/// Apple's page for `receive(minimumIncompleteLength:maximumLength:completion:)` has the completion
	/// deliver "the received content, which may be nil if the message is complete or an error
	/// occurred" -- may be, not is -- and its connection.h says it outright, on the receive
	/// completion's `content`: "Note that the content may be non-NULL even in the case of an error if
	/// there was some data received before the error was encountered. The caller should process all
	/// content it receives, and not necessarily ignore data in case of errors"; and on its `context`,
	/// a TCP connection's one context, once complete, means "receiving a FIN". This read used to throw
	/// `.closed` for any completion marked complete before it looked at the content, so a server's
	/// last words went with the close: the reason for a refusal (RFC 6143 7.1.2: "The server closes
	/// the connection after sending the reason-string") was lost in 2 to 7 of 10 connections over a
	/// LAN, though never on loopback, and the handshake reported no reason at all.
	///
	/// A read that asks for more than remains -- a read of a block, as the kit's are
	/// (`BufferedTransport`) -- meets this every time the bytes and the FIN are both in when it is
	/// made, on loopback as well (measured on macOS 27). Bytes the end left short of `minimumLength`
	/// are not handed over -- content is delivered "when at least the minimum is available, or the
	/// content is complete" (on `minimum_incomplete_length`) -- since no later read could complete
	/// them: the end is this read's to report.
	func read(minimumLength: Int,
			  maximumLength: Int,
			  keepingEndIn end: ReceiveEnd) async throws -> Data {
		if let ended = end.error {
			throw ended
		}

		return try await withCheckedThrowingContinuation { continuation in
			receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { content, _, isComplete, error in
				// An error first: a stream that failed did not also close in good order.
				let ending: (any Error)? = error ?? (isComplete ? VNCError.connection(.closed) : nil)

				if let ending {
					end.record(ending)
				}

				if let content,
				   content.count >= minimumLength,
				   content.count <= maximumLength {
					continuation.resume(returning: content)

					return
				}

				if let ending {
					continuation.resume(throwing: ending)

					return
				}

				guard content != nil else {
					continuation.resume(throwing: VNCError.protocol(.noData))

					return
				}

				continuation.resume(throwing: VNCError.protocol(.invalidData))
			}
		}
	}
}

/// How a connection's incoming stream ended, once a read has seen it end: kept for the reads after
/// the one that brought its last bytes.
///
/// Kept, rather than learnt again from Network.framework: a receive made after the completion that
/// marked the stream complete does not say so again. Measured on macOS 27 over loopback, it completed
/// with no content, `isComplete` false and POSIX error 96, ENODATA, "No message available on STREAM"
/// -- which, handed on, would describe a closed connection as something else.
final class ReceiveEnd: @unchecked Sendable {
	private let lock = NSLock()
	private var ending: (any Error)?

	/// What ended the stream, if anything has.
	var error: (any Error)? {
		lock.lock()
		defer { lock.unlock() }

		return ending
	}

	/// Keeps the first end recorded.
	func record(_ error: any Error) {
		lock.lock()

		if ending == nil {
			ending = error
		}

		lock.unlock()
	}
}

extension NWConnection: NetworkConnectionWriting {
	func write(data: Data) async throws {
		return try await withCheckedThrowingContinuation { continuation in
			send(content: data, completion: .contentProcessed({ error in
				if let error = error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}))
		}
	}
}
#endif
