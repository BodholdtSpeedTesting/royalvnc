#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Bytes a read of the network brought back that no reader has taken yet: a
/// socket's `recv` (SocketNetworkConnection), or a transport's block
/// (`BufferedTransport`).
///
/// Its own object, shared by reference, and locked. Reads use it one at a
/// time -- SocketNetworkConnection's fast path takes from it on the caller's
/// task and its slow path fills it on `queue`; BufferedTransport takes and
/// appends on the caller's task -- so reads never contend with each other.
/// `close()` does: `BufferedTransport.cancelTransport()` calls it on whichever
/// thread ends the session (`VNCConnection.disconnect()`, an app's main
/// thread) while a read may be inside `take`, `count`, `isClosed` or
/// `append`. The lock is what keeps a close from emptying the array under a
/// `take`, and what lets `append(_: Data)` refuse a block that lands after the
/// close. It must not be removed or narrowed. Spinlock where Foundation has no
/// NSLock, as elsewhere in the kit.
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
    private var closed = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }

        return bytes.count - offset
    }

    /// Whether `close()` has been called.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }

        return closed
    }

    func append(_ more: ArraySlice<UInt8>) {
        lock.lock()
        defer { lock.unlock() }

        bytes.append(contentsOf: more)
    }

    /// Appends `more` and returns true, or, once `close()` has been called,
    /// drops it and returns false. The check and the append are one step under
    /// the lock, so no window is left in which a close could come between them
    /// and what came after the close be taken.
    func append(_ more: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !closed else {
            return false
        }

        bytes.append(contentsOf: more)

        return true
    }

    /// Drops whatever is waiting, and makes every later `append(_: Data)` drop
    /// what it is handed and return false. `append(_: ArraySlice<UInt8>)`, the
    /// socket connection's, does not check: that connection never closes its
    /// buffer.
    func close() {
        lock.lock()
        defer { lock.unlock() }

        closed = true
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
