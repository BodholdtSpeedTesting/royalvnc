#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Connect/Disconnect
public extension VNCConnection {
#if canImport(ObjectiveC)
	@objc
#endif
	func connect() {
		beginConnecting()
	}

#if canImport(ObjectiveC)
    @objc
#endif
	func disconnect() {
		beginDisconnecting()
	}
}

// MARK: - Clipboard, for embedders that keep it themselves
public extension VNCConnection {
	/// Sends `text` to the server's clipboard (ClientCutText, RFC 6143 7.5.6),
	/// for an embedder that watches the local clipboard itself -- on Windows and
	/// Linux, where the kit's clipboard monitor has no clipboard to watch. The
	/// text is encoded exactly as the kit's own clipboard text is (see
	/// `VNCProtocol.ClientCutText`). The other direction is
	/// `serverClipboardTextHandler`.
	func sendClipboardText(_ text: String) {
		enqueueClientCutTextMessage(text)
	}
}

public extension VNCConnection {
#if canImport(ObjectiveC)
    @objc
#endif
	func updateColorDepth(_ colorDepth: Settings.ColorDepth) {
		guard let framebuffer = framebuffer else { return }

		let newPixelFormat = VNCProtocol.PixelFormat(depth: colorDepth.rawValue)

		state.pixelFormat = newPixelFormat

		let sendPixelFormatMessage = VNCProtocol.SetPixelFormat(pixelFormat: newPixelFormat)

		clientToServerMessageQueue.enqueue(sendPixelFormatMessage)

		recreateFramebuffer(size: framebuffer.size,
							screens: framebuffer.screens,
							pixelFormat: newPixelFormat)
	}
}

// MARK: - Mouse Input
public extension VNCConnection {
#if canImport(ObjectiveC)
    @objc
#endif
    func mouseMove(x: UInt16, y: UInt16) {
        enqueueMouseEvent(nonNormalizedX: x,
                          nonNormalizedY: y)
    }

#if canImport(ObjectiveC)
    @objc
#endif
    func mouseButtonDown(_ button: VNCMouseButton,
                         x: UInt16, y: UInt16) {
        updateMouseButtonState(button: button,
                               isDown: true)

        enqueueMouseEvent(nonNormalizedX: x,
                          nonNormalizedY: y)
    }

#if canImport(ObjectiveC)
    @objc
#endif
    func mouseButtonUp(_ button: VNCMouseButton,
                       x: UInt16, y: UInt16) {
        updateMouseButtonState(button: button,
                               isDown: false)

        enqueueMouseEvent(nonNormalizedX: x,
                          nonNormalizedY: y)
    }

#if canImport(ObjectiveC)
    @objc
#endif
    func mouseWheel(_ wheel: VNCMouseWheel,
                    x: UInt16, y: UInt16,
                    steps: UInt32) {
        for _ in 0..<steps {
            updateMouseButtonState(wheel: wheel,
                                   isDown: true)

            enqueueMouseEvent(nonNormalizedX: x,
                              nonNormalizedY: y)

            updateMouseButtonState(wheel: wheel,
                                   isDown: false)

            // The release, which used to be computed and never sent. RFC 6143
            // 7.5.5 has no scroll axis: a wheel step *is* "a press and release"
            // of button 4, 5, 6 or 7, so a PointerEvent carrying the cleared bit
            // is half the event and not a tidy-up.
            //
            // Without it, N steps put N identical masks on the wire. A server
            // that derives button transitions by diffing against the previous
            // mask -- the ordinary implementation -- sees one 0-to-1 edge, so
            // steps 2..N are silently dropped and a three-notch flick scrolls
            // once. The wheel button is also left logically held until whatever
            // pointer event the user happens to send next clears it.
            enqueueMouseEvent(nonNormalizedX: x,
                              nonNormalizedY: y)
        }
    }
}

extension VNCConnection {
    func updateMouseButtonState(button: VNCMouseButton,
                                isDown: Bool) {
        updateMouseButtonState(mousePointerButton: button.mousePointerButton,
                               isDown: isDown)
    }

    func updateMouseButtonState(wheel: VNCMouseWheel,
                                isDown: Bool) {
        updateMouseButtonState(mousePointerButton: wheel.mousePointerButton,
                               isDown: isDown)
    }

    func updateMouseButtonState(mousePointerButton: VNCProtocol.MousePointerButton,
                                isDown: Bool) {
        setMouseButton(mousePointerButton, isDown: isDown)
    }
}

// MARK: - Keyboard Input
public extension VNCConnection {
	func keyDown(_ key: VNCKeyCode) {
		enqueueKeyEvent(key: key,
						isDown: true)
	}

#if canImport(ObjectiveC)
	@objc(keyDown:)
#endif
	func _objc_keyDown(_ key: UInt32) {
		keyDown(.init(key))
	}

	func keyUp(_ key: VNCKeyCode) {
		enqueueKeyEvent(key: key,
						isDown: false)
	}

#if canImport(ObjectiveC)
	@objc(keyUp:)
#endif
	func _objc_keyUp(_ key: UInt32) {
		keyUp(.init(key))
	}
}
