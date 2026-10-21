#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

// TODO: All of this is very hacky and NOT fully fleshed out!
final class SocketNetworkConnection: NetworkConnection {
    let settings: NetworkConnectionSettings

    /// What `recv` brought back and no reader has taken yet. See "Reading".
    private let received = ReceivedBytes()

    // This will be replaced when calling start. Calling any other method before start (which would use this placeholder queue) is a programmer error.
    private var queue = DispatchQueue(label: "PLACEHOLDER")

    // The socket, the status and its handler, and whether the connection has
    // been cancelled, under `lock`: `cancel()` comes from whichever thread ends
    // the session (`VNCConnection.disconnect()`, an app's main thread) while the
    // dial runs on `queue`, and reads and writes on others of its threads.
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
    private let lock = Spinlock()
#else
    private let lock = NSLock()
#endif

    /// The connection's socket, from the moment `start` makes it: before it
    /// connects, so that a cancel ends a connect under way too.
    private var socket: Socket?

    private var isCancelled = false

    private var currentStatus: NetworkConnectionStatus = .unknown("None")

    private var statusUpdateHandler: NetworkConnectionStatusUpdateHandler?

    var status: NetworkConnectionStatus {
        locked { currentStatus }
    }

    init(settings: NetworkConnectionSettings) {
#if os(Windows)
        do {
            try Winsock.intializeWinsock()
        } catch {
            fatalError("Initializing Winsock failed: \(error.humanReadableDescription)")
        }
#endif

        self.settings = settings
    }

    func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
        locked { self.statusUpdateHandler = statusUpdateHandler }
    }

    var isReady: Bool {
        switch status {
            case .ready:
                true
            default:
                false
        }
    }

    /// Ends the connection now: a dial under way stops, a read or a write
    /// waiting on another thread returns, and it and every one after it fail as
    /// cancelled; the socket is shut down at once, so the server is sent the
    /// end of the stream now, and closed once nothing uses it (`Socket.cancel()`).
    /// This used to do nothing, and the socket was closed only when the
    /// connection was released -- which a read waiting for a server that sends
    /// nothing prevents. The connection is `.cancelled` from now on, as an
    /// NWConnection is, and says so once; a dial that finishes later says
    /// nothing. From any thread; once.
    func cancel() {
        let cancelling: (socket: Socket?, handler: NetworkConnectionStatusUpdateHandler?)? = locked {
            guard !isCancelled else {
                return nil
            }

            isCancelled = true
            currentStatus = .cancelled

            return (socket, statusUpdateHandler)
        }

        guard let cancelling else {
            return
        }

        cancelling.socket?.cancel()
        cancelling.handler?(.cancelled)
    }

    func start(queue: DispatchQueue) {
        self.queue = queue

        // Refused once cancelled: a cancelled connection stays so.
        guard update(to: .preparing) else {
            return
        }

        queue.async { [weak self] in
            guard let self else { return }

#if DEBUG
            Self.beforeDialingForTests?()
#endif

            do {
                let addressInfo = try AddressInfo(host: settings.host,
                                                               port: settings.port)

                let socket = try Socket(addressInfo: addressInfo)

                // Kept before it connects, so that a cancel ends the connect as
                // well as what follows it. One made after the cancel is never
                // connected.
                guard adopt(socket) else {
                    socket.cancel()

                    return
                }

                try socket.connect()

                update(to: .ready)
            } catch {
                // A socket that did not connect is let go of; after a cancel, the
                // connection stays `.cancelled` (`update`).
                locked { self.socket = nil }

                update(to: .failed(error))
            }
        }
    }

#if DEBUG
    /// For the tests alone: called by a dial of any connection as it begins, before the address is
    /// looked up and the socket made -- so that a test can cancel the connection with its dial under
    /// way, or see that a dial began at all. Nil but in a test that sets it, and set only while that
    /// test runs.
    nonisolated(unsafe) static var beforeDialingForTests: (() -> Void)?
#endif

    /// Keeps `socket` as the connection's, unless it has been cancelled.
    private func adopt(_ socket: Socket) -> Bool {
        locked {
            guard !isCancelled else {
                return false
            }

            self.socket = socket

            return true
        }
    }

    /// Moves to `newStatus` and tells the handler -- outside the lock, as the
    /// handler may call back in -- unless the connection has been cancelled.
    /// False when refused.
    @discardableResult
    private func update(to newStatus: NetworkConnectionStatus) -> Bool {
        let accepted: (Bool, NetworkConnectionStatusUpdateHandler?) = locked {
            guard !isCancelled else {
                return (false, nil)
            }

            currentStatus = newStatus

            return (true, statusUpdateHandler)
        }

        accepted.1?(newStatus)

        return accepted.0
    }

    /// The socket for a read or a write: once the connection is ready, and until
    /// it is cancelled.
    private func readySocket() throws -> Socket {
        try locked {
            guard !isCancelled else {
                throw VNCError.connection(.cancelled)
            }

            guard case .ready = currentStatus,
                  let socket else {
                throw Socket.Errors.socketCreationFailed(underlyingErrorCode: nil)
            }

            return socket
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }

        return try body()
    }
}

// MARK: - Reading
//
// Buffered. Every field the decoders read is its own `read` -- an RRE
// subrectangle is five of them, a pixel and four UInt16s -- and each one used
// to cost a hop onto `queue`, a `recv(2)` and a continuation resume, however
// many bytes were already waiting in the kernel. Measured on Linux (debug
// build, swift:6.2, four CPUs): one 256x512 RRE frame of 114,558
// subrectangles, 1.37 MB, took 27-28 seconds to decode, about 48 microseconds
// per read, where the same frame over NWConnection on macOS took 5.5. Now a
// `recv` asks for up to 64 KiB, and reads are served from what it brought
// back without leaving the caller's task until it runs out.
extension SocketNetworkConnection: NetworkConnectionReading {
	func read(minimumLength: Int,
              maximumLength: Int) async throws -> Data {
        let socket = try readySocket()

        let wanted = max(minimumLength, 1)
        let received = self.received

        if let ready = received.take(minimumLength: wanted, maximumLength: maximumLength) {
            return ready
        }

        let queue = self.queue
        let chunkSize = max(ReceivedBytes.chunkSize, maximumLength)

		return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // Until the minimum is here: `minimumLength` is a promise to
                // the caller, where a single `recv` used to return short and
                // then fail the read as invalid data.
                while received.count < wanted {
                    var buffer = [UInt8](repeating: 0, count: chunkSize)

                    switch socket.receive(buffer: &buffer) {
                        // Handle connection closure
                        case .transferred(0):
                            continuation.resume(throwing: Errors.connectionClosed)

                            return

                        case .transferred(let bytesRead):
                            received.append(buffer.prefix(bytesRead))

                        // The error `recv` reported, kept. This used to throw
                        // `VNCError.protocol(.noData)` for every failure, so a
                        // server resetting the connection read as a protocol
                        // fault -- "No Data was retrieved" -- and nothing said
                        // what the network had done. NWConnection hands over its
                        // error as it is; this now says as much.
                        case .failed(let errorCode):
                            continuation.resume(throwing: Errors.receiveFailed(underlyingErrorCode: errorCode))

                            return

                        // Cancelled, while it waited for the server or before:
                        // as a read of a cancelled NWConnection fails.
                        case .cancelled:
                            continuation.resume(throwing: VNCError.connection(.cancelled))

                            return
                    }
                }

                guard let data = received.take(minimumLength: wanted,
                                               maximumLength: maximumLength) else {
                    continuation.resume(throwing: VNCError.protocol(.invalidData))

                    return
                }

                continuation.resume(returning: data)
            }
        }
	}
}

// MARK: - Writing
extension SocketNetworkConnection: NetworkConnectionWriting {
	func write(data: Data) async throws {
        let queue = self.queue

        let socket = try readySocket()

		return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let bytesToSend = [UInt8](data)

                switch socket.send(buffer: bytesToSend) {
                    case .transferred:
                        continuation.resume()

                    case .failed(let errorCode):
                        continuation.resume(throwing: Errors.sendFailed(underlyingErrorCode: errorCode))

                    case .cancelled:
                        continuation.resume(throwing: VNCError.connection(.cancelled))
                }
            }
        }
	}
}

// MARK: - Errors
private extension SocketNetworkConnection {
    // MARK: - Enum for Socket Errors
    //
    // Also `CustomStringConvertible`, with the same text. An embedder that
    // interpolates the error it was handed -- `"\(error)"` -- would otherwise
    // get `receiveFailed(underlyingErrorCode: 104)`, and the point of keeping
    // the code is that the message says what happened: "Receive failed:
    // Connection reset by peer (errno 104)".
    enum Errors: LocalizedError, CustomStringConvertible {
        case sendFailed(underlyingErrorCode: Int32)
        case receiveFailed(underlyingErrorCode: Int32)
        case connectionClosed

        var errorDescription: String? {
            switch self {
                case .sendFailed(let underlyingErrorCode):
                    "Send failed: \(Socket.describe(errorCode: underlyingErrorCode))"
                case .receiveFailed(let underlyingErrorCode):
                    "Receive failed: \(Socket.describe(errorCode: underlyingErrorCode))"
                case .connectionClosed:
                    "Connection closed"
            }
        }

        var description: String {
            errorDescription ?? "Socket error"
        }
    }
}
