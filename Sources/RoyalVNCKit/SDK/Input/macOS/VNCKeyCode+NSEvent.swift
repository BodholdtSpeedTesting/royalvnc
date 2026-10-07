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
	///   where that is the key's own character: the same as `charactersIgnoringModifiers`, or,
	///   both being ASCII, its capital -- what Caps Lock makes of a letter. RFC 6143 §7.5.4 makes
	///   the case of a keysym significant ("a server receiving an upper case 'A' keysym without
	///   any shift presses should interpret it as an upper case 'A'"), makes Shift "only ... a
	///   hint", and tells a server to "ignore "lock" keysyms such as CapsLock" and "interpret
	///   each character-based keysym according to its case" -- so Caps Lock reaches the server
	///   as capitals, and is not sent as a key of its own. `charactersIgnoringModifiers` cannot
	///   carry it: AppKit gives it "as if no modifier key (except for Shift) applies", lower case
	///   under Caps Lock.
	/// * Any other `characters` sends `charactersIgnoringModifiers`, as every key did before:
	///   - an empty one, as NSEvent documents it for a dead key ("an empty string") --
	///     `charactersIgnoringModifiers` is then "the non-modifier key character pressed for dead
	///     keys";
	///   - one that carries a dead key still pending, as a keystroke "can produce more than one
	///     character (for example, “à” is composed of ‘a’ and ‘`‘)" (Apple's Cocoa Event Handling
	///     Guide): the accent and the key ("';" after US International's two ' dead keys, of
	///     which the second types ' and leaves the first pending), or what they compose ("é" on
	///     the e key). The dead key went to the server already, as its own
	///     `charactersIgnoringModifiers`, and composing is the server's: sent `characters`, it would
	///     be given the accent twice;
	///   - what Caps Lock puts on a key beyond an ASCII capital: É for é on a French layout, İ for
	///     i on a Turkish one, “ for 2 on Hebrew - QWERTY. A server can lack the capital where it
	///     has the lower case (X's French keymap has a key for é and none for É), and the kit sends
	///     a character beyond Latin-1 as its bare code point (`withCharacter`), which is not the
	///     keysym X11 gives it (that is the code point plus 0x1000000); so Caps Lock reaches the
	///     server as ASCII capitals only, where before it did not reach it at all.
	/// * A shortcut -- Command, Control or Option held -- sends `charactersIgnoringModifiers`,
	///   the key's character with Shift alone: those modifiers are the server's to apply ("the
	///   state of modifier keys such as Control and Alt should be taken as modifying the
	///   interpretation of other keysyms", and Control-A is "a Control press followed by an 'a'
	///   press"), and `characters` would carry Control-C as U+0003, Option-e as nothing, and
	///   Command or Option with Caps Lock as a capital on the layouts that give one there.
	/// * The key after a dead key (`completingDeadKey`, `isDeadKey(characters:charactersIgnoringModifiers:)`)
	///   sends `charactersIgnoringModifiers` too, as every key did before, whatever its `characters`.
	///   With the rule above, that changes what is sent only where its `characters` is its own
	///   ASCII capital: Caps Lock does not apply to it -- after Estonian's Option-A, which types
	///   nothing and is a dead key to `isDeadKey`, Caps Lock and B send 'b'.
	static func keyCodesFrom(cgKeyCode: CGKeyCode,
							 characters: String?,
							 charactersIgnoringModifiers: String?,
							 modifierFlags: NSEvent.ModifierFlags,
							 completingDeadKey: Bool = false) -> [VNCKeyCode] {
		let isShortcut = !modifierFlags.intersection([ .command, .control, .option ]).isEmpty
		let typed = characters ?? ""
		let ignoring = charactersIgnoringModifiers ?? ""

		// An empty `characters` is never the key's own character but where both strings are
		// empty, and either sends nothing.
		let isOwnCharacter = typed == ignoring
			|| (typed.allSatisfy(\.isASCII) && typed == ignoring.uppercased())

		let sent = isShortcut || completingDeadKey || !isOwnCharacter
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
	/// key character pressed for dead keys". The two strings cannot tell a dead key from a key that
	/// types nothing on the level in use but has a character with Shift alone: Estonian's Option-A
	/// types nothing and starts no dead key, and has Option-e's strings, so it counts as one, and the
	/// key after it goes as its `charactersIgnoringModifiers`, without Caps Lock. Where Shift alone
	/// gives nothing too (Apple's Hebrew layout with Shift on most letter keys), both strings are
	/// empty, and the key is no dead key. Nor is a key whose `characters` is not empty, though a
	/// dead key may still be pending (US International's ' pressed a second time types ' and leaves
	/// the first pending): the key after it carries the accent in its own `characters`.
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
