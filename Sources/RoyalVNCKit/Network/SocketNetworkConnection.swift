#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

// TODO: All of this is very hacky and NOT fully fleshed out!
final class SocketNetworkConnection: NetworkConnection {
    let settings: NetworkConnectionSettings

    private var socket: Socket?

    /// What `recv` brought back and no reader has taken yet. See "Reading".
    private let received = ReceivedBytes()

    // This will be replaced when calling start. Calling any other method before start (which would use this placeholder queue) is a programmer error.
    private var queue = DispatchQueue(label: "PLACEHOLDER")

    private(set) var statusUpdateHandler: NetworkConnectionStatusUpdateHandler?

    private(set) var status: NetworkConnectionStatus = .unknown("None") {
        didSet {
            statusUpdateHandler?(status)
        }
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
        self.statusUpdateHandler = statusUpdateHandler
    }

    var isReady: Bool {
        switch status {
            case .ready:
                true
            default:
                false
        }
    }

    func cancel() {
        // TODO
        // fatalError("Not implemented")
    }

    func start(queue: DispatchQueue) {
        self.status = .preparing
        self.queue = queue

        queue.async { [weak self] in
            guard let self else { return }

            do {
                let addressInfo = try AddressInfo(host: settings.host,
                                                               port: settings.port)

                let socket = try Socket(addressInfo: addressInfo)

                try socket.connect()

                self.socket = socket
                self.status = .ready
            } catch {
                self.status = .failed(error)
            }
        }
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
        guard let socket else {
            throw Socket.Errors.socketCreationFailed(underlyingErrorCode: nil)
        }

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
                    let bytesRead = socket.receive(buffer: &buffer)

                    // Handle connection closure
                    if bytesRead == 0 {
                        continuation.resume(throwing: Errors.connectionClosed)

                        return
                    }

                    // Handle errors during receiving
                    if bytesRead < 0 {
                        continuation.resume(throwing: VNCError.protocol(.noData))

                        return
                    }

                    received.append(buffer.prefix(bytesRead))
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

/// Bytes a `recv` brought back that no reader has taken yet.
///
/// Its own object, shared by reference with the closure that fills it, and
/// locked: the fast path in `read` takes from it on the caller's task and the
/// slow path fills it on `queue`. Reads are sequential, so the lock is never
/// contended; it is there so that stays true by construction rather than by
/// the callers' good behaviour. Spinlock where Foundation has no NSLock, as
/// elsewhere in the kit.
private final class ReceivedBytes: @unchecked Sendable {
    /// How much one `recv` asks for.
    static let chunkSize = 64 * 1024

#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
    private let lock = Spinlock()
#else
    private let lock = NSLock()
#endif

    private var bytes = [UInt8]()
    private var offset = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return bytes.count - offset
    }

    func append(_ more: ArraySlice<UInt8>) {
        lock.lock()
        defer { lock.unlock() }

        bytes.append(contentsOf: more)
    }

    /// Up to `maximumLength` bytes, or `nil` if fewer than `minimumLength`
    /// are waiting.
    func take(minimumLength: Int, maximumLength: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let available = bytes.count - offset

        guard available >= minimumLength, available > 0 else { return nil }

        let taken = min(available, maximumLength)
        let data = Data(bytes[offset..<(offset + taken)])

        offset += taken

        if offset == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset >= Self.chunkSize {
            bytes.removeFirst(offset)
            offset = 0
        }

        return data
    }
}

// MARK: - Writing
extension SocketNetworkConnection: NetworkConnectionWriting {
	func write(data: Data) async throws {
        let queue = self.queue

        guard let socket else {
            throw Socket.Errors.socketCreationFailed(underlyingErrorCode: nil)
        }

		return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let bytesToSend = [UInt8](data)
                let bytesSent = socket.send(buffer: bytesToSend)

                if bytesSent < 0 {
                    continuation.resume(throwing: Errors.sendFailed)
                } else {
                    continuation.resume()
                }
            }
        }
	}
}

// MARK: - Errors
private extension SocketNetworkConnection {
    // MARK: - Enum for Socket Errors
    enum Errors: LocalizedError {
        case sendFailed
        case connectionClosed

        var errorDescription: String? {
            switch self {
                case .sendFailed:
                    "Send failed"
                case .connectionClosed:
                    "Connection closed"
            }
        }
    }
}
