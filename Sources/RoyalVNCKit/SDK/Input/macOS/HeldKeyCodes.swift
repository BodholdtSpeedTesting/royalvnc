#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// What each key a view on a connection saw go down sent -- at its press, or at the last repeat
/// that changed it -- by its Mac key code (NSEvent's `keyCode`), so that the key comes up as
/// exactly that; and, for a key whose keysyms a server may read by Shift, whether Shift was held
/// when it was sent. Kept with the connection (VNCConnection's `heldKeyCodes`), so that a key held
/// while an embedder puts a new view on the connection comes up as the old view pressed it.
///
/// A key's characters can change between its key-down and its key-up: Shift or Caps Lock
/// pressed or let go in between, or a layout whose other level puts another character on the
/// key (Turkish i and İ, a Hebrew - PC letter and its Latin capital). A server knows a key
/// only by its keysym (RFC 6143 §7.5.4), so a key-up worked out again from the key-up event
/// would let go of a keysym that was never pressed and leave the one that was, held.
struct HeldKeyCodes {
	private var sent: [UInt16: (keys: [VNCKeyCode], shift: Bool)] = [:]

	init() { }

	/// A key went down, Shift held or not (`shift`: the event's, where Shift is significant to the
	/// key, `VNCKeyCode.isShiftSignificant(cgKeyCode:)`, and false for any other); returns the keys to
	/// let go of first and the keys to press.
	///
	/// An auto-repeat of a key held here sends `keyCodes()`, worked out again: what the key types
	/// now. Where that is what its press sent, under the same `shift`, the repeat re-sends it. Where
	/// the modifiers have changed it since (Shift pressed or let go mid-repeat: 'h' held repeats as
	/// 'H'), it lets go of what the key sent and presses the new keys, which its key-up then sends --
	/// so the server types what the Mac does, and holds no key no release will name. Where only
	/// `shift` has changed -- Caps Lock on, 'A' held while Shift is let go or pressed, the Mac typing
	/// 'A' still -- it lets go of the keys and presses them again. A server is sent this view's Shift
	/// and never its Caps Lock, and is to "interpret each character-based keysym according to its
	/// case" (§7.5.4); but one that presses a held key again at each repeat does so under the Shift it
	/// holds then, which would type the capital's key in lower case once Shift is let go. Pressed
	/// anew, the key is decided by its keysym again. Caps Lock is not compared: the server never sees
	/// it. Nor is Shift, for a key it is not significant to (`shift` false whatever the Shift): Space
	/// or an arrow held while Shift goes down is re-sent, never let go of mid-hold.
	///
	/// A press of a key still held here -- its key-up never reached the view: it went to another
	/// window or application, or AppKit kept it back -- first lets go of what that press sent, which
	/// the server still holds. Otherwise the key sends `keyCodes()`, remembered with its `shift`
	/// until its key-up. A repeat of a key never seen going down is a press.
	mutating func keyDown(_ keyCode: UInt16,
						  isARepeat: Bool,
						  shift: Bool,
						  keyCodes: () -> [VNCKeyCode]) -> (released: [VNCKeyCode], pressed: [VNCKeyCode]) {
		if isARepeat,
		   let held = sent[keyCode] {
			let now = keyCodes()

			guard now != held.keys || shift != held.shift else {
				return ([ ], held.keys)
			}

			sent[keyCode] = (now, shift)

			return (held.keys, now)
		}

		let released = sent.removeValue(forKey: keyCode)?.keys ?? [ ]
		let pressed = keyCodes()

		sent[keyCode] = (pressed, shift)

		return (released, pressed)
	}

	/// A key came up; returns the keys to let go of: what its key-down sent, or `keyCodes()`
	/// for a key never seen going down -- held across a reconnect, which is a new connection.
	mutating func keyUp(_ keyCode: UInt16,
						keyCodes: () -> [VNCKeyCode]) -> [VNCKeyCode] {
		sent.removeValue(forKey: keyCode)?.keys ?? keyCodes()
	}

	/// Whether every key seen going down has been seen coming up.
	var isEmpty: Bool {
		sent.isEmpty
	}
}
#endif
