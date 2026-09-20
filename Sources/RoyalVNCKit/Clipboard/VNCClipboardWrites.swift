#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The pasteboard changes this process made on a server's behalf.
///
/// The pasteboard belongs to the whole process, not to a connection. When a
/// server sends ServerCutText the client writes that text to it, which bumps
/// the change count — and every connection's monitor then sees a change it
/// cannot attribute. Without somewhere to record who caused it, a monitor
/// cannot tell the client's own write from the user pressing Cmd-C.
///
/// Two things went wrong because of that. A connection sent the server its own
/// clipboard straight back, half a second after receiving it. And with two
/// sessions open, one server's clipboard travelled to the *other* server —
/// text the user never copied, arriving on a machine they never sent it to,
/// with nothing to tell them it had happened.
///
/// This is deliberately process-wide rather than per-connection. A
/// per-connection record fixes only the echo: connection B's monitor knows
/// nothing about connection A's write, and B is the one that leaks it.
///
/// What it does NOT do, and should not: text the *user* copies on this machine
/// still reaches every session that shares its clipboard. That is the feature.
/// The only changes suppressed here are the ones this client made itself.
enum VNCClipboardWrites {
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
    private static let lock = Spinlock()
#else
    private static let lock = NSLock()
#endif

    /// A few, not one.
    ///
    /// Two connections can each receive a ServerCutText within one monitor
    /// interval, and each write bumps the count again. Keeping only the last
    /// would let the earlier one through to whichever monitor had not ticked
    /// yet. Eight is far more than the 0.5s window can hold and costs nothing.
    private static var recent: [Int] = []

    private static let limit = 8

    /// Records that this client produced the pasteboard's current state.
    static func record(_ changeCount: Int) {
        lock.lock()

        defer { lock.unlock() }

        recent.append(changeCount)

        if recent.count > limit {
            recent.removeFirst(recent.count - limit)
        }
    }

    /// Whether the pasteboard's current state came from this client rather than
    /// from the person using it.
    static func wasOurs(_ changeCount: Int) -> Bool {
        lock.lock()

        defer { lock.unlock() }

        return recent.contains(changeCount)
    }
}
