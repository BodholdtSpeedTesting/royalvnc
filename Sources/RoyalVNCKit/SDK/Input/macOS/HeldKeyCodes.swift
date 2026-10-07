#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// What each key the view saw go down sent, by its Mac key code (NSEvent's `keyCode`), so that
/// the key comes up as exactly that.
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
	/// An auto-repeat re-sends what the key's press sent, whatever the modifiers have become
	/// since. A press of a key still held here -- its key-up never reached this view: it went to
	/// another window or application, or AppKit kept it back -- first lets go of what that press
	/// sent, which the server still holds. Otherwise the key sends `keyCodes()`, remembered until
	/// its key-up. A repeat of a key this view never saw go down is a press.
	mutating func keyDown(_ keyCode: UInt16,
						  isARepeat: Bool,
						  keyCodes: () -> [VNCKeyCode]) -> (released: [VNCKeyCode], pressed: [VNCKeyCode]) {
		if isARepeat,
		   let pressed = sent[keyCode] {
			return ([ ], pressed)
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
