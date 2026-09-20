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
	func read(minimumLength: Int,
              maximumLength: Int) async throws -> Data {
		return try await withCheckedThrowingContinuation { continuation in
			receive(minimumIncompleteLength: minimumLength, maximumLength: maximumLength) { content, _, isComplete, error in
				guard !isComplete else {
					continuation.resume(throwing: VNCError.connection(.closed))

					return
				}

				guard error == nil else {
					continuation.resume(throwing: error!)

					return
				}

				guard let content else {
					continuation.resume(throwing: VNCError.protocol(.noData))

					return
				}

				let receivedLength = content.count

				guard receivedLength >= minimumLength,
					  receivedLength <= maximumLength else {
					continuation.resume(throwing: VNCError.protocol(.invalidData))

					return
				}

				continuation.resume(returning: content)
			}
		}
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
