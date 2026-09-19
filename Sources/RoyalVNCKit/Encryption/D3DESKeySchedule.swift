#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Serialises everything that touches d3des's key schedule.
///
/// `d3des.c` keeps the schedule in a file-scope global:
///
///     static unsigned int KnL[32] = { 0L };
///
/// `deskey()` writes it and `des()` reads it, so a caller has to hold both
/// calls together or another thread's `deskey()` lands between them and the
/// blocks after that point are encrypted with somebody else's key.
///
/// Nothing serialised them. Two connections authenticating at the same time
/// interleaved as:
///
///     A: deskey(keyA)      schedule = A
///     B: deskey(keyB)      schedule = B
///     A: des(block)        encrypted with B's key
///
/// which corrupts part of A's credential while leaving the rest correct,
/// because A's remaining blocks may run before or after B's `deskey` again.
///
/// **How it was found.** A test asserting MS-Logon II reached a framebuffer
/// failed about one full test run in eight, and only on Linux, and never once
/// in isolation -- 120 consecutive handshakes on macOS and 80 on Linux all
/// passed. The server's own log is what identified it: the shared secret and
/// the derived DES key were IDENTICAL on both sides, one credential field
/// decrypted correctly and the other was garbage, and which of the two was
/// garbage varied. A wrong key cannot do that; only a key that changed
/// half-way through can.
///
/// This is not specific to MS-Logon II. `VNCDESEncryption.encrypt` runs the
/// same two calls for ordinary VNC password authentication, so two overlapping
/// connections could corrupt each other's password there too -- which a user
/// sees as a correct password being rejected.
///
/// A lock rather than making d3des reentrant, because the whole of DES here is
/// one 16-byte challenge or a 320-byte credential, once per connection, at
/// authentication time. There is nothing to contend over and nothing to gain
/// from a wider change to vendored C.
///
/// The lock is chosen the way the rest of the kit chooses one: `Spinlock` on
/// the platforms whose Foundation does not carry `NSLock` -- the kit imports
/// `FoundationEssentials` where it can, and on Linux that import succeeds
/// without bringing `NSLock` with it. Same shape as `VNCConnection` and
/// `VNCFramebufferMallocAllocator`.
enum D3DESKeySchedule {
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
    private static let lock = Spinlock()
#else
    private static let lock = NSLock()
#endif

    /// Runs `body` with exclusive use of the key schedule.
    ///
    /// Every `deskey`/`des` pair in the kit goes through here. A caller that
    /// takes only one of the two inside the lock has not fixed anything.
    static func withExclusiveUse<T>(_ body: () -> T) -> T {
        lock.lock()

        defer { lock.unlock() }

        return body()
    }
}
