#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bytes a read of the network brought back that no reader has taken yet: a
/// socket's `recv` (SocketNetworkConnection), or a transport's block
/// (`BufferedTransport`).
///
/// Its own object, shared by reference, and locked: SocketNetworkConnection's
/// fast path takes from it on the caller's task and its slow path fills it on
/// `queue`. Reads are sequential, so the lock is never contended; it is there so
/// that stays true by construction rather than by the callers' good behaviour.
/// Spinlock where Foundation has no NSLock, as elsewhere in the kit.
final class ReceivedBytes: @unchecked Sendable {
    /// How much one read of the network asks for.
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

    func append(_ more: Data) {
        lock.lock()
        defer { lock.unlock() }

        bytes.append(contentsOf: more)
    }

    /// Drops whatever is waiting.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        bytes.removeAll()
        offset = 0
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
