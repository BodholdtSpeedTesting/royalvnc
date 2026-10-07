#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AppKit

extension VNCKeyCode {
	/// The keys a Mac key event sends.
	///
	/// A key with a keysym of its own -- Return, Tab, Escape, the arrows, the function keys,
	/// the modifiers (`from(cgKeyCode:)`) -- is that keysym, whatever the modifiers. Any other
	/// key is the keysyms of one of the event's two strings (`keyCodesFrom(characters:)`):
	///
	/// * Typing -- no Command, Control or Option held -- sends `characters`, what the key types,
	///   with Shift and Caps Lock applied. RFC 6143 §7.5.4 makes the case of a keysym
	///   significant ("a server receiving an upper case 'A' keysym without any shift presses
	///   should interpret it as an upper case 'A'"), makes Shift "only ... a hint", and tells a
	///   server to "ignore "lock" keysyms such as CapsLock" and "interpret each character-based
	///   keysym according to its case" -- so Caps Lock reaches the server as capitals, and is
	///   not sent as a key of its own. `charactersIgnoringModifiers` cannot carry it: AppKit
	///   gives it "as if no modifier key (except for Shift) applies", lower case under Caps Lock.
	/// * A shortcut -- Command, Control or Option held -- sends `charactersIgnoringModifiers`,
	///   the key's character with Shift alone: those modifiers are the server's to apply ("the
	///   state of modifier keys such as Control and Alt should be taken as modifying the
	///   interpretation of other keysyms", and Control-A is "a Control press followed by an 'a'
	///   press"), and `characters` would carry Control-C as U+0003 and Option-e as nothing.
	/// * A dead key, whose `characters` is "an empty string" (NSEvent), sends
	///   `charactersIgnoringModifiers`, "the non-modifier key character pressed for dead keys",
	///   as every key did before -- and so does any key whose `characters` is empty.
	/// * The key after a dead key (`completingDeadKey`, `isDeadKey(characters:charactersIgnoringModifiers:)`)
	///   sends `charactersIgnoringModifiers` too, as every key did before. Its `characters` is what
	///   the dead key and it make together -- a keystroke "can produce more than one character
	///   (for example, “à” is composed of ‘a’ and ‘`‘)" (Apple's Cocoa Event Handling Guide) --
	///   and the server was sent the dead key already, as above: it would be given the accent
	///   twice, '`' and then 'à', or Option-e (which a Mac server's own layout may make the acute
	///   dead key) and then 'é'.
	static func keyCodesFrom(cgKeyCode: CGKeyCode,
							 characters: String?,
							 charactersIgnoringModifiers: String?,
							 modifierFlags: NSEvent.ModifierFlags,
							 completingDeadKey: Bool = false) -> [VNCKeyCode] {
		let isShortcut = !modifierFlags.intersection([ .command, .control, .option ]).isEmpty
		let typed = characters ?? ""

		let sent = isShortcut || completingDeadKey || typed.isEmpty
			? charactersIgnoringModifiers
			: typed

		return keyCodesFrom(cgKeyCode: cgKeyCode,
							characters: sent)
	}

	/// The keys a key event sends, from its key code, its two strings and its modifier flags, and
	/// whether it is the key after a dead key. Valid for key-down and key-up events only, as
	/// NSEvent's own properties are.
	static func keyCodesFrom(event: NSEvent,
							 completingDeadKey: Bool = false) -> [VNCKeyCode] {
		keyCodesFrom(cgKeyCode: CGKeyCode(event.keyCode),
					 characters: event.characters,
					 charactersIgnoringModifiers: event.charactersIgnoringModifiers,
					 modifierFlags: event.modifierFlags,
					 completingDeadKey: completingDeadKey)
	}

	/// The keys a key event sends as its `charactersIgnoringModifiers`, whatever the modifiers:
	/// what every key event sent before `keyCodesFrom(event:)`.
	static func keyCodesIgnoringModifiersFrom(event: NSEvent) -> [VNCKeyCode] {
		keyCodesFrom(cgKeyCode: CGKeyCode(event.keyCode),
					 characters: event.charactersIgnoringModifiers)
	}

	/// Whether a key event is a dead key's: its `characters` empty, as NSEvent documents it "for
	/// dead keys, such as Option-e", and its `charactersIgnoringModifiers` not -- "the non-modifier
	/// key character pressed for dead keys". A key with nothing on the level in use has neither
	/// (Apple's Hebrew layout with Shift on most letter keys), and is no dead key.
	static func isDeadKey(characters: String?,
						  charactersIgnoringModifiers: String?) -> Bool {
		(characters ?? "").isEmpty && !(charactersIgnoringModifiers ?? "").isEmpty
	}

	/// Whether a Mac key code is a modifier's -- Shift, Control, Option and Command on either side,
	/// Caps Lock, Function -- which goes down between a dead key and the key that completes it
	/// (Shift for a capital) and is neither.
	static func isModifier(cgKeyCode: CGKeyCode) -> Bool {
		modifierKeyCodes.contains(cgKeyCode)
	}

	private static let modifierKeyCodes: Set<CGKeyCode> = [
		CGKeyCodes.shift, CGKeyCodes.rightShift,
		CGKeyCodes.control, CGKeyCodes.rightControl,
		CGKeyCodes.option, CGKeyCodes.rightOption,
		CGKeyCodes.command, CGKeyCodes.rightCommand,
		CGKeyCodes.capsLock, CGKeyCodes.function
	]
}
#endif
