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

	private(set) var isMonitoring = false

#if !canImport(FoundationEssentials)
	private var timer: Timer?
#endif

	/// The change count this monitor has already accounted for.
	///
	/// Guarded, because it is now written from two places: the timer, which runs
	/// on the main queue, and `acknowledgeCurrentContents()`, which the receive
	/// path calls from the connection's own queue.
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

		stopMonitoring()
	}
}

extension VNCClipboardMonitor {
	func startMonitoring() {
		stopMonitoring()

		// -1 to send clipboard to trigger notification immediately if something's on the pasteboard
		lastChangeCount = clipboard.changeCount - 1

#if !canImport(FoundationEssentials)
		guard timer == nil else { // Already have a timer
			return
		}

		DispatchQueue.main.async { [weak self] in
			guard let self else { return }

            let timer = Timer.scheduledTimer(withTimeInterval: self.monitoringInterval,
                                             repeats: true,
                                             block: timerDidFire(_:))

			timer.tolerance = self.tolerance

            self.timer = timer
            self.isMonitoring = true
		}
#endif
	}

	func stopMonitoring() {
#if !canImport(FoundationEssentials)
		timer?.invalidate()
		timer = nil
#endif

		lastChangeCount = 0
		isMonitoring = false
	}
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
