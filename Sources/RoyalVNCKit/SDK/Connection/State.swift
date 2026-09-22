#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCConnection {
    final class State {
		/// The stop flag for both loops, and the only field here that is
		/// genuinely shared between threads.
		///
		/// It is written once, by `beginDisconnecting`, on whichever thread
		/// asked to disconnect, and read continuously by two detached `Task`s --
		/// the send loop (`VNCConnection+Send.swift:13` and `:63`) and the
		/// receive loop (`VNCConnection+Receive.swift:13` and `:27`). Nothing
		/// serialised them, and Thread Sanitizer reported it:
		///
		///     WARNING: ThreadSanitizer: data race
		///       Write of size 1 by thread T10:
		///         VNCConnection.beginDisconnecting(error:)
		///         VNCConnection.disconnect()
		///       Previous read of size 1 by thread T6:
		///         VNCConnection.send()
		///
		/// A torn `Bool` is not the worry on the platforms this ships to. The
		/// missing barrier is: without one there is no guarantee either loop
		/// ever observes the write, so `disconnect()` can leave a loop spinning
		/// against a socket that is being torn down underneath it.
		///
		/// The rest of this type is deliberately left alone. Those fields are
		/// filled during the handshake, which is one sequence on one task, and
		/// read afterwards; none of them has been shown to race. If one is,
		/// it gets this same treatment rather than a blanket lock that would
		/// make the claim without the evidence.
		var disconnectRequested: Bool {
			get {
				disconnectRequestedLock.lock()
				defer { disconnectRequestedLock.unlock() }

				return disconnectRequestedStorage
			}
			set {
				disconnectRequestedLock.lock()
				disconnectRequestedStorage = newValue
				disconnectRequestedLock.unlock()
			}
		}

		/// Raises the flag, and says whether this call is the one that raised it.
		///
		/// `beginDisconnecting` used to read the flag and then write it, which
		/// is two locked steps with a gap between them: two threads calling
		/// `disconnect()` at once could both see `false` and both go on to
		/// cancel the connection and post `.disconnecting` twice. Testing and
		/// setting under one lock closes that, and is why the caller asks this
		/// rather than reading the property.
		func requestDisconnect() -> Bool {
			disconnectRequestedLock.lock()
			defer { disconnectRequestedLock.unlock() }

			guard !disconnectRequestedStorage else { return false }

			disconnectRequestedStorage = true

			return true
		}

		private var disconnectRequestedStorage = false

		// Spinlock on the platforms whose Foundation does not carry NSLock;
		// same shape as `VNCConnection.negotiatedSecurityMethodLock`.
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
		private let disconnectRequestedLock = Spinlock()
#else
		private let disconnectRequestedLock = NSLock()
#endif

		var serverProtocolVersion: VNCProtocol.ProtocolVersion?
		var agreedProtocolVersion: VNCProtocol.ProtocolVersion?

		var isTightSecurityEnabled = false

		var framebufferWidth: UInt16 = 0
		var framebufferHeight: UInt16 = 0

		var serverPixelFormat: VNCProtocol.PixelFormat?
		var pixelFormat: VNCProtocol.PixelFormat?

		var desktopName: String?

		var incrementalUpdatesEnabled = false

		var areContinuousUpdatesSupported = false
		var areContinuousUpdatesEnabled = false
	}
}

extension VNCConnection.State {
	var isAppleRemoteDesktop: Bool {
		return serverProtocolVersion?.isAppleRemoteDesktop ?? false
	}
}
