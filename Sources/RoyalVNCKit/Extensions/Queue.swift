#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A FIFO queue that may be used from more than one thread at once.
///
/// WHY THIS IS SYNCHRONISED, AND WHY IT IS A CLASS.
///
/// This was a `struct` wrapping a bare `[T]`, and its only user is
/// `VNCConnection.clientToServerMessageQueue` -- which is appended to from
/// whichever thread the embedder calls `mouseMove`, `keyDown` or the clipboard
/// from, usually the main one, and drained by `VNCConnection.send()` running in
/// the detached `Task` that `startSendLoop()` creates. `VNCConnection` is a
/// plain class, not an actor, so nothing serialised those two.
///
/// That is `Array.append` racing `Array.removeFirst` on one buffer. Thread
/// Sanitizer reported it eighteen times in a single run of the input tests:
///
///     WARNING: ThreadSanitizer: Swift access race
///       Modifying access by thread T1:
///         VNCConnection.enqueueClientToServerMessage(_:)
///         VNCConnection.mouseButtonDown(_:x:y:)
///       Previous modifying access by thread T8:
///         VNCConnection.send()
///
/// The consequence is not theoretical. A racing append and removeFirst can
/// reallocate the storage under the other thread, so it corrupts or traps in
/// the send path of every session, while somebody is moving the pointer.
///
/// A class rather than a struct because a lock has to be shared, not copied: a
/// `struct` holding a lock gives every copy its own, which synchronises
/// nothing. Value semantics were never wanted here -- there is exactly one
/// queue and it is referenced, never assigned.
///
/// LOCKED INSIDE RATHER THAN AT THE CALL SITES, because a computed property on
/// the owner would not have worked. `queue.enqueue(x)` through a locked
/// `get`/`set` pair is a read, a mutation of the copy, and a write back: three
/// steps with the lock released between them, which is still a race and a
/// subtler one. Every operation here is one atomic step instead.
final class Queue<T> {
	private var list = [T]()

	// Spinlock on the platforms whose Foundation does not carry NSLock. The kit
	// imports FoundationEssentials where it can, and on Linux that import
	// succeeds without bringing NSLock with it, so a bare `NSLock()` here
	// compiles on Apple platforms and fails everywhere else. Same shape as
	// `VNCConnection.negotiatedSecurityMethodLock`.
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
	private let lock = Spinlock()
#else
	private let lock = NSLock()
#endif

	func enqueue(_ element: T) {
		lock.lock()
		defer { lock.unlock() }

		list.append(element)
	}

	func dequeue() -> T? {
		lock.lock()
		defer { lock.unlock() }

		// `list.isEmpty` and not `self.isEmpty`. The property below takes the
		// same lock, and neither `NSLock` nor `Spinlock` is recursive, so
		// calling it from in here would deadlock the send loop on its first
		// message -- which is what the original `guard !isEmpty` became the
		// moment a lock was added.
		guard !list.isEmpty else { return nil }

		return list.removeFirst()
	}

	func clear() {
		lock.lock()
		defer { lock.unlock() }

		list.removeAll()
	}

	func peek() -> T? {
		lock.lock()
		defer { lock.unlock() }

		return list.first
	}

	var isEmpty: Bool {
		lock.lock()
		defer { lock.unlock() }

		return list.isEmpty
	}
}
