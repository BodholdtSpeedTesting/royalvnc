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
	private let changeCountLock = NSLock()
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
	/// Marks whatever is on the clipboard right now as already seen.
	///
	/// Called after the *client* writes the clipboard on the server's behalf, so
	/// that the monitor does not mistake its own write for something the user
	/// copied and send it straight back.
	///
	/// Without this, every ServerCutText bounced. Measured against this project's
	/// stand-in: the server sent `SENTINEL-FROM-THE-SERVER` and the client
	/// returned the identical 24 bytes as ClientCutText half a second later. With
	/// two sessions open it is worse than wasted traffic -- one server's clipboard
	/// reaches the other, because the monitor cannot tell which connection caused
	/// a change to a pasteboard the whole process shares.
	func acknowledgeCurrentContents() {
		lastChangeCount = clipboard.changeCount
	}

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

		guard let text = clipboard.text else { // No text
			return
		}

		delegate.clipboardMonitor(self,
								  didChangeText: text)
	}
}
#endif
