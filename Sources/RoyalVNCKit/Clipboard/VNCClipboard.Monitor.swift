#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

final class VNCClipboardMonitor {
	let clipboard: VNCClipboard
	let monitoringInterval: TimeInterval
	let tolerance: TimeInterval

	weak var delegate: VNCClipboardMonitorDelegate?

	/// Whether a timer is running. Main queue only, for the same reason as
	/// `timer`.
	private(set) var isMonitoring = false

#if !canImport(FoundationEssentials)
	/// The polling timer. MAIN QUEUE ONLY: it is created, compared, invalidated
	/// and cleared there and nowhere else.
	///
	/// It used to be created on the main queue -- `startMonitoring()` hops there
	/// to schedule it -- and read, invalidated and cleared by `stopMonitoring()`
	/// on whichever thread the connection happened to be changing state on:
	/// the handshake task, the receive loop when a server hangs up, or the
	/// embedder's thread on `disconnect()`. Thread Sanitizer reported it from
	/// the embedder's suite in both directions:
	///
	///     WARNING: ThreadSanitizer: data race
	///       Read of size 8 by thread T15:
	///         VNCClipboardMonitor.stopMonitoring() VNCClipboard.Monitor.swift:102
	///         VNCConnection.stopMonitoringClipboard()
	///         VNCConnection.updateConnectionState(_:)
	///         VNCConnection.beginDisconnecting(error:)
	///         VNCConnection.handleBreakingError(_:)
	///         closure #1 in VNCConnection.startReceiveLoop()
	///       Previous write of size 8 by main thread:
	///         closure #1 in VNCClipboardMonitor.startMonitoring() VNCClipboard.Monitor.swift:94
	///
	///     WARNING: ThreadSanitizer: data race
	///       Write of size 8 by main thread:
	///         closure #1 in VNCClipboardMonitor.startMonitoring() VNCClipboard.Monitor.swift:94
	///       Previous write of size 8 by thread T8:
	///         VNCClipboardMonitor.stopMonitoring() VNCClipboard.Monitor.swift:103
	///
	/// The second is worse than a race on a pointer. The stop ran FIRST, found
	/// no timer yet, and cleared nothing; the start's hop then ran on the main
	/// queue and scheduled a repeating timer for a session that had already
	/// ended. Nothing invalidated it until the connection itself was freed --
	/// and then from whatever thread that happened on -- so until then it
	/// polled the pasteboard every half second, keeping this monitor alive
	/// through its block. A session that ends before the main queue gets round
	/// to the start -- a server that drops at once, a main thread that is busy
	/// -- left one running. And `Timer.invalidate()` must be sent from the
	/// thread the timer was installed on, which the off-main stop never was.
	///
	/// Confining it to the main queue fixes all three: the stop now goes behind
	/// any start still waiting there, so they happen in the order they were
	/// asked for, and the start checks whether it is still wanted when it runs.
	/// No lock, because there is nothing left to share.
	private var timer: Timer?
#endif

	/// The change count this monitor has already accounted for.
	///
	/// Guarded, because it is written from two threads: by `startMonitoring()`
	/// and `stopMonitoring()`, on whichever thread the connection changes state
	/// on, and by the timer, which runs on the main queue.
	// Spinlock where Foundation does not carry NSLock. The kit imports
	// FoundationEssentials where it can, and on Linux that import succeeds
	// without bringing NSLock with it -- the same shape VNCConnection and
	// VNCFramebufferMallocAllocator already use.
#if canImport(Glibc) || canImport(Android) || canImport(WinSDK)
	private let changeCountLock = Spinlock()
#else
	private let changeCountLock = NSLock()
#endif
	private var lastChangeCountStorage = 0

	private var lastChangeCount: Int {
		get {
			changeCountLock.lock()
			defer { changeCountLock.unlock() }

			return lastChangeCountStorage
		}
		set {
			changeCountLock.lock()
			lastChangeCountStorage = newValue
			changeCountLock.unlock()
		}
	}

	init(clipboard: VNCClipboard,
		 monitoringInterval: TimeInterval,
		 tolerance: TimeInterval) {
		self.clipboard = clipboard
		self.monitoringInterval = monitoringInterval
		self.tolerance = tolerance
	}

	deinit {
		delegate = nil

		// No `stopMonitoring()` here any more, and nothing to stop. A running
		// timer's block holds this monitor strongly, so one that is being freed
		// has no timer left to invalidate -- and hopping to the main queue with
		// a monitor mid-deinit would be the one thing worse than the race it
		// used to have, touching `timer` from whatever thread the last
		// reference happened to die on.
	}
}

extension VNCClipboardMonitor {
	/// Safe from any thread. The timer itself is scheduled on the main queue.
	func startMonitoring() {
		// -1 to send clipboard to trigger notification immediately if something's on the pasteboard
		lastChangeCount = clipboard.changeCount - 1

#if !canImport(FoundationEssentials)
		DispatchQueue.main.async { [weak self] in
			guard let self else { return }

			// Replaces a running timer rather than adding a second one, which is
			// what the `stopMonitoring()` this method used to begin with did.
			self.invalidateTimer()

			// ASKED NOW, when the timer would start, not when this was queued.
			// A disconnect records its state before it asks for the stop, so a
			// start that reaches the main queue after the session has already
			// ended sees that here and schedules nothing -- rather than a timer
			// that its stop, having run first, can no longer reach.
			guard let delegate = self.delegate,
				  delegate.clipboardMonitorShouldMonitor(self) else {
				return
			}

			// Holds this monitor strongly until invalidated, which is what lets
			// `deinit` assume there is no timer left.
			let timer = Timer.scheduledTimer(withTimeInterval: self.monitoringInterval,
											 repeats: true) { [self] timer in
				self.timerDidFire(timer)
			}

			timer.tolerance = self.tolerance

			self.timer = timer
			self.isMonitoring = true
		}
#endif
	}

	/// Safe from any thread. The timer is invalidated on the main queue, behind
	/// any start still waiting there.
	func stopMonitoring() {
		lastChangeCount = 0

#if !canImport(FoundationEssentials)
		DispatchQueue.main.async { [weak self] in
			self?.invalidateTimer()
		}
#endif
	}

#if !canImport(FoundationEssentials)
	/// Main queue only.
	private func invalidateTimer() {
		dispatchPrecondition(condition: .onQueue(.main))

		timer?.invalidate()
		timer = nil
		isMonitoring = false
	}
#endif
}

#if !canImport(FoundationEssentials)
private extension VNCClipboardMonitor {
	func timerDidFire(_ timer: Timer) {
		guard let delegate,
			  timer == self.timer else {
			return
		}

		guard delegate.clipboardMonitorShouldMonitor(self) else { // Should not monitor
			return
		}

		let currentChangeCount = clipboard.changeCount

		guard currentChangeCount != lastChangeCount else { // No changes
			return
		}

		lastChangeCount = currentChangeCount

		// A change this client made on a server's behalf, not something the
		// person at this machine copied. Sending it on would either hand the
		// server its own clipboard back or hand it another session's. See
		// `VNCClipboardWrites`.
		guard !VNCClipboardWrites.wasOurs(currentChangeCount) else { return }

		guard let text = clipboard.text else { // No text
			return
		}

		delegate.clipboardMonitor(self,
								  didChangeText: text)
	}
}
#endif
