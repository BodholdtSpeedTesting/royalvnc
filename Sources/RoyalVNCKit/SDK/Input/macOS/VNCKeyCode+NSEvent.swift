#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AppKit
import Carbon

extension VNCKeyCode {
	/// The keys a Mac key event sends.
	///
	/// A key with a keysym of its own -- Return, Tab, Escape, the arrows, the function keys,
	/// the modifiers (`from(cgKeyCode:)`) -- is that keysym, whatever the modifiers. Any other
	/// key is the keysyms of one of the event's two strings (`keyCodesFrom(characters:)`):
	///
	/// * Typing -- no Command, Control or Option held -- sends `characters`, what the key types,
	///   where that is the key's own character (`isOwnCharacter`): the same as
	///   `charactersIgnoringModifiers`, or what the key types at the event's Shift and Caps Lock
	///   with no dead key pending (`charactersWithoutDeadKeys`, `charactersWithoutDeadKeys(of:)`)
	///   and within keysymdef.h's Latin-1 (U+0020-U+007E and U+00A0-U+00FF, `hasLatin1Keysym`).
	///   That is what Caps Lock makes of a letter -- 'A', 'É', 'Ä' -- and
	///   whatever else a layout puts on its Caps Lock level: the English letters of Apple's Hebrew,
	///   the digits of Arabic and of French - Numerical. RFC 6143 §7.5.4 makes the case of a keysym
	///   significant ("a server receiving an upper case 'A' keysym without any shift presses should
	///   interpret it as an upper case 'A'"), makes Shift "only ... a hint", and tells a server to
	///   "ignore "lock" keysyms such as CapsLock" and "interpret each character-based keysym
	///   according to its case" -- so Caps Lock reaches the server as what it types, and is not
	///   sent as a key of its own. `charactersIgnoringModifiers` cannot carry it: AppKit gives it
	///   "as if no modifier key (except for Shift) applies", without Caps Lock.
	/// * Any other `characters` sends `charactersIgnoringModifiers`, as every key did before:
	///   - an empty one, as NSEvent documents it for a dead key ("an empty string") --
	///     `charactersIgnoringModifiers` is then "the non-modifier key character pressed for dead
	///     keys";
	///   - one that carries a dead key still pending, as a keystroke "can produce more than one
	///     character (for example, “à” is composed of ‘a’ and ‘`‘)" (Apple's Cocoa Event Handling
	///     Guide): the accent and the key ("';" after US International's two ' dead keys, of
	///     which the second types ' and leaves the first pending), or what they compose ("é" on
	///     the e key). Neither is what the key types with no dead key pending. The dead key went to
	///     the server already, as its own `charactersIgnoringModifiers`, and composing is the
	///     server's: sent `characters`, it would be given the accent twice;
	///   - a character beyond Latin-1: İ for i on a Turkish layout under Caps Lock, “ for 2 on
	///     Hebrew - QWERTY. The kit sends such a character as its bare code point (`withCharacter`),
	///     which is not the keysym X11 gives it (that is the code point plus 0x1000000), and no
	///     server maps 0x130 to İ; a Latin-1 character's keysym is its code point;
	///   - a control character, which keysymdef.h's Latin-1 leaves out (U+0000-U+001F,
	///     U+007F-U+009F): U+0003 at Caps Lock on the § key of Apple's Arabic layout, U+0010 on
	///     Thai's JIS Eisu and Kana keys. `withCharacter` would send a C0 control or DEL as its code
	///     point, which is no keysym -- keysymdef.h gives the control keys keysyms of their own,
	///     BackSpace 0xff08 among them -- and a C1 control as nothing.
	/// * A shortcut -- Command, Control or Option held -- sends `charactersIgnoringModifiers`,
	///   the key's character with Shift alone: those modifiers are the server's to apply ("the
	///   state of modifier keys such as Control and Alt should be taken as modifying the
	///   interpretation of other keysyms", and Control-A is "a Control press followed by an 'a'
	///   press"), and `characters` would carry Control-C as U+0003, Option-e as nothing, and
	///   Command or Option with Caps Lock as a capital on the layouts that give one there.
	/// * The key after a dead key (`completingDeadKey`, `isDeadKey(characters:charactersIgnoringModifiers:)`)
	///   sends `charactersIgnoringModifiers` too, as every key did before, whatever its `characters`.
	///   With the rule above, that changes what is sent only where its `characters` is its own and
	///   not its `charactersIgnoringModifiers`: Caps Lock does not apply to it -- after Estonian's
	///   Option-A, which types nothing and is a dead key to `isDeadKey`, Caps Lock and B send 'b'.
	///
	/// `charactersWithoutDeadKeys` is nil where the layout could not be asked; then the rule is the
	/// one before it: `characters` where it is `charactersIgnoringModifiers` or, both being ASCII,
	/// that string's capital.
	static func keyCodesFrom(cgKeyCode: CGKeyCode,
							 characters: String?,
							 charactersIgnoringModifiers: String?,
							 charactersWithoutDeadKeys: String?,
							 modifierFlags: NSEvent.ModifierFlags,
							 completingDeadKey: Bool = false) -> [VNCKeyCode] {
		let isShortcut = !modifierFlags.intersection([ .command, .control, .option ]).isEmpty
		let typed = characters ?? ""

		let isOwn = isOwnCharacter(typed,
								   charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
								   charactersWithoutDeadKeys: charactersWithoutDeadKeys)

		let sent = isShortcut || completingDeadKey || !isOwn
			? charactersIgnoringModifiers
			: typed

		return keyCodesFrom(cgKeyCode: cgKeyCode,
							characters: sent)
	}

	/// Whether a key event's `characters` is its key's own character, and so sent as typed:
	///
	/// * where it is the key's `charactersIgnoringModifiers` -- either string, the same;
	/// * never where it is empty and that is not: a dead key's, or a key with nothing on the level in
	///   use, sends `charactersIgnoringModifiers`, whatever the layout says the key types alone;
	/// * else where it is what the key types at the event's Shift and Caps Lock with no dead key
	///   pending (`charactersWithoutDeadKeys`), and each of its characters has a Latin-1 keysym
	///   (`hasLatin1Keysym`): not a control character, which has none;
	/// * where the layout could not be asked (`charactersWithoutDeadKeys` nil), where both are ASCII
	///   and it is `charactersIgnoringModifiers`' capital, as before.
	static func isOwnCharacter(_ characters: String,
							   charactersIgnoringModifiers: String,
							   charactersWithoutDeadKeys: String?) -> Bool {
		if characters == charactersIgnoringModifiers {
			return true
		}

		if characters.isEmpty {
			return false
		}

		guard let charactersWithoutDeadKeys else {
			return characters.allSatisfy(\.isASCII)
				&& characters == charactersIgnoringModifiers.uppercased()
		}

		return characters == charactersWithoutDeadKeys
			&& characters.unicodeScalars.allSatisfy(hasLatin1Keysym)
	}

	/// Whether a character is one of keysymdef.h's Latin-1 characters -- "Latin 1 (ISO/IEC 8859-1 =
	/// Unicode U+0020..U+00FF)", XK_space 0x0020 to XK_asciitilde 0x007e and XK_nobreakspace 0x00a0
	/// to XK_ydiaeresis 0x00ff -- each of which has its code point as its keysym. Not a control
	/// character, U+0000-U+001F or U+007F-U+009F, which has no keysym there.
	static func hasLatin1Keysym(_ scalar: Unicode.Scalar) -> Bool {
		(0x20...0x7e).contains(scalar.value)
			|| (0xa0...0xff).contains(scalar.value)
	}

	/// Whether what a server makes of a key's keysyms can turn on Shift, so that the Shift it went
	/// down under is remembered with them, and a repeat under another Shift pressed anew
	/// (HeldKeyCodes):
	///
	/// * a key with no keysym of its own (`from(cgKeyCode:)` nil), whose keysyms are characters: a
	///   capital under Caps Lock, which a server pressing its held key again under the Shift it holds
	///   then would type in the other case; a keypad digit, which a server types by its layout's
	///   number-row key -- '%' under Shift where the Mac types '5';
	/// * the keypad's =, which a server with no such key types as the character '=' by the key that
	///   carries it -- '+' under Shift on a US layout, where the Mac types '='.
	///
	/// Not any other key with a keysym of its own -- Space, Return, Tab, Delete, Escape, the arrows,
	/// Home, End, Page Up and Down, Help, F1-F19, the keypad's Clear, /, *, -, +, Enter and decimal
	/// point, the modifiers. Its keysym is the same whatever Shift, and a server that presses a held
	/// one again at a repeat does so under the Shift it holds then, to the same effect as a new press:
	/// Shift and an arrow, a space. Pressed anew, the key would be let go of mid-hold for nothing,
	/// which a program that reads keys sees -- a held Space released.
	static func isShiftSignificant(cgKeyCode: CGKeyCode) -> Bool {
		from(cgKeyCode: cgKeyCode) == nil
			|| cgKeyCode == CGKeyCodes.ansiKeypadEquals
	}

	/// The keys a key event sends, from its key code, its two strings, what its key types at its Shift
	/// and Caps Lock with no dead key pending (`charactersWithoutDeadKeys(of:)`, or a test's own), its
	/// modifier flags, and whether it is the key after a dead key. Valid for key-down and key-up events
	/// only, as NSEvent's own properties are.
	static func keyCodesFrom(event: NSEvent,
							 charactersWithoutDeadKeys: String?,
							 completingDeadKey: Bool = false) -> [VNCKeyCode] {
		keyCodesFrom(cgKeyCode: CGKeyCode(event.keyCode),
					 characters: event.characters,
					 charactersIgnoringModifiers: event.charactersIgnoringModifiers,
					 charactersWithoutDeadKeys: charactersWithoutDeadKeys,
					 modifierFlags: event.modifierFlags,
					 completingDeadKey: completingDeadKey)
	}

	/// What a key event's key types on the current keyboard layout at the event's Shift and Caps Lock
	/// alone, with no dead key pending; nil where the layout cannot be asked. The layout is
	/// TISCopyCurrentKeyboardLayoutInputSource's -- "the keyboard layout currently being used", or the
	/// one an input method uses -- by its kTISPropertyUnicodeKeyLayoutData ('uchr' data, NULL for a
	/// layout that has none) (TextInputSources.h), and the keyboard type LMGetKbdType's, as
	/// UCKeyTranslate's documentation says to pass (UnicodeUtilities.h). Must be called on the main
	/// thread, as key events are handled.
	///
	/// UnicodeUtilities.h discourages UCKeyTranslate in applications and points to NSEvent's
	/// charactersByApplyingModifiers:, but that documents only that it "will not affect the dead key
	/// state for current text input" (NSEvent.h), not that it starts from none; started from a pending
	/// dead key, it would answer with what that composes, the very string this question tells apart.
	/// UCKeyTranslate is given its dead-key state, here none.
	static func charactersWithoutDeadKeys(of event: NSEvent) -> String? {
		guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
			return nil
		}

		return withExtendedLifetime(source) {
			guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
				return nil
			}

			let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()

			guard let bytes = CFDataGetBytePtr(data) else {
				return nil
			}

			return charactersWithoutDeadKeys(cgKeyCode: CGKeyCode(event.keyCode),
											 modifierFlags: event.modifierFlags,
											 keyboardLayout: UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
											 keyboardType: UInt32(LMGetKbdType()))
		}
	}

	/// What `cgKeyCode` types on `keyboardLayout` ('uchr' data) at the Shift and Caps Lock of
	/// `modifierFlags` alone -- Command, Control and Option dropped -- with no dead key pending; nil
	/// where UCKeyTranslate fails. UCKeyTranslate (UnicodeUtilities.h): a key going down
	/// (kUCKeyActionDown); the modifier key state "((EventRecord.modifiers) >> 8) & 0xFF", Shift being
	/// shiftKey and Caps Lock alphaLock (Events.h; 0x02 and 0x04); a dead-key state "initialized to
	/// zero", none pending; and kUCKeyTranslateNoDeadKeysMask, which "Prevents setting any new dead-key
	/// states", so a dead key answers with its own character ('^', the spacing '´'), not nothing.
	static func charactersWithoutDeadKeys(cgKeyCode: CGKeyCode,
										  modifierFlags: NSEvent.ModifierFlags,
										  keyboardLayout: UnsafePointer<UCKeyboardLayout>,
										  keyboardType: UInt32) -> String? {
		var modifierKeyState: UInt32 = 0

		if modifierFlags.contains(.shift) {
			modifierKeyState |= UInt32(shiftKey >> 8) & 0xff
		}

		if modifierFlags.contains(.capsLock) {
			modifierKeyState |= UInt32(alphaLock >> 8) & 0xff
		}

		var deadKeyState: UInt32 = 0
		var length = 0
		var units = [UniChar](repeating: 0, count: 16)

		let status = UCKeyTranslate(keyboardLayout,
									UInt16(cgKeyCode),
									UInt16(kUCKeyActionDown),
									modifierKeyState,
									keyboardType,
									OptionBits(kUCKeyTranslateNoDeadKeysMask),
									&deadKeyState,
									units.count,
									&length,
									&units)

		guard status == noErr else {
			return nil
		}

		return String(utf16CodeUnits: units,
					  count: length)
	}

	/// The keys a key event sends as its `charactersIgnoringModifiers`, whatever the modifiers:
	/// what every key event sent before `keyCodesFrom(event:charactersWithoutDeadKeys:completingDeadKey:)`.
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
