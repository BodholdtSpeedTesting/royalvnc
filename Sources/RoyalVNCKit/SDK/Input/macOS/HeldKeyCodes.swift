#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// What each key the view saw go down sent -- at its press, or at the last repeat that changed
/// it -- by its Mac key code (NSEvent's `keyCode`), so that the key comes up as exactly that.
///
/// A key's characters can change between its key-down and its key-up: Shift or Caps Lock
/// pressed or let go in between, or a layout whose other level puts another character on the
/// key (Turkish i and İ, a Hebrew - PC letter and its Latin capital). A server knows a key
/// only by its keysym (RFC 6143 §7.5.4), so a key-up worked out again from the key-up event
/// would let go of a keysym that was never pressed and leave the one that was, held.
struct HeldKeyCodes {
	private var sent: [UInt16: [VNCKeyCode]] = [:]

	init() { }

	/// A key went down; returns the keys to let go of first and the keys to press.
	///
	/// An auto-repeat of a key held here sends `keyCodes()`, worked out again: what the key types
	/// now. Where that is what its press sent, the repeat re-sends it; where the modifiers have
	/// changed it since (Shift pressed or let go mid-repeat: 'h' held repeats as 'H'), it lets go
	/// of what the key sent and presses the new keys, which its key-up then sends -- so the server
	/// types what the Mac does, and holds no key no release will name. A press of a key still held
	/// here -- its key-up never reached this view: it went to another window or application, or
	/// AppKit kept it back -- first lets go of what that press sent, which the server still holds.
	/// Otherwise the key sends `keyCodes()`, remembered until its key-up. A repeat of a key this
	/// view never saw go down is a press.
	mutating func keyDown(_ keyCode: UInt16,
						  isARepeat: Bool,
						  keyCodes: () -> [VNCKeyCode]) -> (released: [VNCKeyCode], pressed: [VNCKeyCode]) {
		if isARepeat,
		   let pressed = sent[keyCode] {
			let now = keyCodes()

			guard now != pressed else {
				return ([ ], pressed)
			}

			sent[keyCode] = now

			return (pressed, now)
		}

		let released = sent.removeValue(forKey: keyCode) ?? [ ]
		let pressed = keyCodes()

		sent[keyCode] = pressed

		return (released, pressed)
	}

	/// A key came up; returns the keys to let go of: what its key-down sent, or `keyCodes()`
	/// for a key this view never saw go down.
	mutating func keyUp(_ keyCode: UInt16,
						keyCodes: () -> [VNCKeyCode]) -> [VNCKeyCode] {
		sent.removeValue(forKey: keyCode) ?? keyCodes()
	}

	/// Whether every key seen going down has been seen coming up.
	var isEmpty: Bool {
		sent.isEmpty
	}
}
#endif
