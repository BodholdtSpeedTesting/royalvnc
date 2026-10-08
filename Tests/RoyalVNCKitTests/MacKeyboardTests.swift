#if os(macOS)
// The Mac framebuffer view's keyboard: which of a key event's strings a key sends, and that a key
// comes up as exactly what it went down as.
//
// Key events are made with NSEvent.keyEvent(with:...) and handed to the code directly -- the
// view's own keyDown(with:), keyUp(with:) and flagsChanged(with:) -- and never posted. The view
// has no window, and its connection never connects: what it would send is read off the
// connection's send queue. Key codes are Events.h's kVK_ constants. A key's strings on a named
// layout are those Apple's layout gives (UCKeyTranslate on the layout's data, read by its ID and
// never selected): `characters` carrying the dead-key state -- the premise, from Apple's Cocoa
// Event Handling Guide, that AppKit composes a pending dead key into it --
// `charactersIgnoringModifiers` at Shift alone with no dead keys, and what the key types at its
// Shift and Caps Lock with no dead keys, which the view asks the current layout for
// (`charactersWithoutDeadKeys`) and the tests give it, as `own` -- by default the key's
// `characters`, where no dead key is pending. The question itself is asked of named layouts' data,
// read the same way (MacKeyCharactersWithoutDeadKeysTests); only its tests against the current
// layout read this Mac's, and they select none.

import XCTest
import AppKit
import Carbon
@testable import RoyalVNCKit

private enum Key {
	static let a: UInt16 = 0x00            // kVK_ANSI_A
	static let s: UInt16 = 0x01            // kVK_ANSI_S
	static let h: UInt16 = 0x04            // kVK_ANSI_H
	static let x: UInt16 = 0x07            // kVK_ANSI_X
	static let c: UInt16 = 0x08            // kVK_ANSI_C
	static let b: UInt16 = 0x0b            // kVK_ANSI_B
	static let e: UInt16 = 0x0e            // kVK_ANSI_E
	static let one: UInt16 = 0x12          // kVK_ANSI_1: '&' on French - Numerical, '١' on Arabic
	static let two: UInt16 = 0x13          // kVK_ANSI_2: 'é' on a French layout
	static let equal: UInt16 = 0x18        // kVK_ANSI_Equal
	static let minus: UInt16 = 0x1b        // kVK_ANSI_Minus
	static let zero: UInt16 = 0x1d         // kVK_ANSI_0
	static let leftBracket: UInt16 = 0x21  // kVK_ANSI_LeftBracket: the '^' dead key on a French layout
	static let i: UInt16 = 0x22            // kVK_ANSI_I: 'ı' and 'I' on Turkish Q
	static let quote: UInt16 = 0x27        // kVK_ANSI_Quote: 'i' and 'İ' on Turkish Q; the ' and " dead keys on US International - PC; 'ä' on German
	static let backslash: UInt16 = 0x2a    // kVK_ANSI_Backslash
	static let semicolon: UInt16 = 0x29    // kVK_ANSI_Semicolon: 'ñ' on Spanish - ISO
	static let space: UInt16 = 0x31        // kVK_Space
	static let command: UInt16 = 0x37      // kVK_Command
	static let shift: UInt16 = 0x38        // kVK_Shift
	static let capsLock: UInt16 = 0x39     // kVK_CapsLock
	static let option: UInt16 = 0x3a       // kVK_Option
	static let keypad5: UInt16 = 0x57      // kVK_ANSI_Keypad5
	static let leftArrow: UInt16 = 0x7b    // kVK_LeftArrow
}

private func keyEvent(_ type: NSEvent.EventType,
					  _ keyCode: UInt16,
					  _ characters: String,
					  ignoring charactersIgnoringModifiers: String,
					  flags: NSEvent.ModifierFlags = [ ],
					  repeat isARepeat: Bool = false) -> NSEvent {
	NSEvent.keyEvent(with: type,
					 location: .zero,
					 modifierFlags: flags,
					 timestamp: 0,
					 windowNumber: 0,
					 context: nil,
					 characters: characters,
					 charactersIgnoringModifiers: charactersIgnoringModifiers,
					 isARepeat: isARepeat,
					 keyCode: keyCode)!
}

/// A keyboard layout's 'uchr' data (kTISPropertyUnicodeKeyLayoutData), read through Text Input Sources -- never
/// selected or enabled.
private func layoutData(_ source: TISInputSource) throws -> [UInt8] {
	let raw = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
	let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
	var bytes = [UInt8](repeating: 0, count: CFDataGetLength(data))
	CFDataGetBytes(data, CFRange(location: 0, length: bytes.count), &bytes)

	return bytes
}

/// A named layout's data, by its input source ID ("com.apple.keylayout.Hebrew").
private func layoutData(id: String) throws -> [UInt8] {
	let filter = [ kTISPropertyInputSourceID as String: id ] as CFDictionary
	let list = try XCTUnwrap(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], id)

	return try layoutData(try XCTUnwrap(list.first, id))
}

/// What `keyCode` types on this Mac's current keyboard layout -- its data read, the layout never selected -- at
/// Shift and Caps Lock (alphaLock) as given, with no dead keys processed (UCKeyTranslate,
/// kUCKeyTranslateNoDeadKeysMask), at this Mac's keyboard type: worked out here, apart from the kit's own.
private func currentLayoutTypes(_ keyCode: UInt16, shift: Bool, capsLock: Bool) throws -> String {
	let bytes = try layoutData(try XCTUnwrap(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()))

	var deadKeyState: UInt32 = 0
	var length = 0
	var units = [UniChar](repeating: 0, count: 16)
	let modifiers = UInt32((shift ? shiftKey : 0) | (capsLock ? alphaLock : 0)) >> 8
	let status: OSStatus = bytes.withUnsafeBytes { buffer in
		UCKeyTranslate(buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
					   UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
					   OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units)
	}
	XCTAssertEqual(status, noErr)

	return String(utf16CodeUnits: units, count: length)
}

/// Which string a key-down sends: VNCKeyCode.keyCodesFrom(event:charactersWithoutDeadKeys:completingDeadKey:).
final class MacKeyEventKeyCodesTests: XCTestCase {
	/// What the event sends, its key typing `own` at its Shift and Caps Lock with no dead key pending -- by
	/// default its `characters`, which carry no dead key.
	private func sent(_ event: NSEvent, own: String? = nil) -> [UInt32] {
		VNCKeyCode.keyCodesFrom(event: event,
								charactersWithoutDeadKeys: own ?? event.characters).map(\.rawValue)
	}

	func testTypingSendsWhatTheKeyTypesWithCapsLockAndShiftApplied() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "A", ignoring: "a", flags: .capsLock)), [ 0x41 ],
					   "Caps Lock: the capital, where charactersIgnoringModifiers stays lower case")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "A", ignoring: "A", flags: [ .capsLock, .shift ])), [ 0x41 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "A", ignoring: "A", flags: .shift)), [ 0x41 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "a", ignoring: "a")), [ 0x61 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.minus, "_", ignoring: "_", flags: .shift)), [ 0x5f ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.two, "é", ignoring: "é")), [ 0xe9 ], "Latin-1 as itself")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.i, "I", ignoring: "ı", flags: .capsLock)), [ 0x49 ],
					   "Turkish Q's ı key under Caps Lock: I, an ASCII capital, though ı is not ASCII")
	}

	func testWhatALayoutPutsOnItsCapsLockLevelGoesAsItTypes() {
		// Apple's layout data: Hebrew types English at Caps Lock, Arabic and French - Numerical their digits.
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.h, "h", ignoring: "\u{5D9}", flags: .capsLock)), [ 0x68 ],
					   "Hebrew's H key at Caps Lock types h: h, not the Hebrew letter its charactersIgnoringModifiers is")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.h, "H", ignoring: "", flags: [ .capsLock, .shift ])), [ 0x48 ],
					   "and H at Caps Lock and Shift, where Shift alone types nothing")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.h, "H", ignoring: "\u{5D9}", flags: .capsLock)), [ 0x48 ],
					   "Hebrew - PC's H key at Caps Lock: H")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.one, "1", ignoring: "\u{661}", flags: .capsLock)), [ 0x31 ],
					   "Arabic's 1 key at Caps Lock types 1, not ١")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.one, "1", ignoring: "&", flags: .capsLock)), [ 0x31 ],
					   "French - Numerical's 1 key at Caps Lock types 1, not &")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "q", ignoring: "Q", flags: [ .capsLock, .shift ])), [ 0x71 ],
					   "French - Numerical's Q key at Caps Lock and Shift types q, not Q")
	}

	func testCapsLocksLatin1CapitalsGoAsThemselves() {
		// A Latin-1 character's keysym is its code point.
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.two, "É", ignoring: "é", flags: .capsLock)), [ 0xc9 ], "French: É")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.quote, "Ä", ignoring: "ä", flags: .capsLock)), [ 0xc4 ], "German: Ä")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.semicolon, "Ñ", ignoring: "ñ", flags: .capsLock)), [ 0xd1 ], "Spanish - ISO: Ñ")
	}

	func testWhatCapsLockMakesBeyondLatin1SendsTheCharacterIgnoringModifiers() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.quote, "İ", ignoring: "i", flags: .capsLock)), [ 0x69 ],
					   "Turkish Q: i, not İ's bare code point, 0x130, which is not the keysym X11 gives İ")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.two, "\u{201C}", ignoring: "2", flags: .capsLock)), [ 0x32 ],
					   "Hebrew - QWERTY puts “ on the 2 key at Caps Lock: 2, as before")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.h, "\u{5D9}", ignoring: "H", flags: [ .capsLock, .shift ])), [ 0x48 ],
					   "Hebrew - PC's H key at Caps Lock and Shift types the Hebrew letter: H, as before")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.quote, "İ", ignoring: "İ", flags: [ .capsLock, .shift ])), [ 0x130 ],
					   "Turkish Q with Shift as well: the one string either way, as before")
	}

	func testACharactersCarryingAPendingDeadKeySendsTheCharacterIgnoringModifiers() {
		// US International - PC: ' is a dead key; pressed again it types ' and leaves the first pending, and ; then
		// types "';". The French '^' likewise, before x.
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.quote, "'", ignoring: "'")), [ 0x27 ], "the second ': its own")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.semicolon, "';", ignoring: ";"), own: ";"), [ 0x3b ],
					   "the accent and ;: ;, the accent having gone already")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.zero, "\")", ignoring: ")", flags: .shift), own: ")"), [ 0x29 ],
					   "\" \" ), likewise")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.x, "^x", ignoring: "x"), own: "x"), [ 0x78 ], "French ^ ^ x")
		// Czech - QWERTY: ´ is a dead key; pressed again it types ' and leaves a state pending, in which Shift-´ -- the
		// ˇ dead key -- types ' too. Not the key's own: ˇ, as before, not any ASCII character there.
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.equal, "'", ignoring: "\u{2C7}", flags: .shift), own: "\u{2C7}"),
					   [ 0x2c7 ], "Czech - QWERTY ´ ´ Shift-´")
	}

	func testAShortcutSendsTheKeyWithShiftAlone() {
		// `own`: what the key types at Shift and Caps Lock alone, the shortcut's modifiers dropped.
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "a", ignoring: "a", flags: [ .command, .capsLock ]), own: "A"), [ 0x61 ],
					   "Caps Lock under a shortcut: Command and a (NSEvent.keyEvent itself lowercases both strings under "
					   + "Command and Caps Lock, so this cannot tell Command apart)")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "\u{1}", ignoring: "a", flags: .control), own: "a"), [ 0x61 ],
					   "Control-A is Control and a, not U+0001")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "\u{1}", ignoring: "A", flags: [ .control, .shift ]), own: "A"), [ 0x41 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "å", ignoring: "a", flags: .option), own: "a"), [ 0x61 ],
					   "Option-a is Alt and a, not the character Option types here")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.equal, "+", ignoring: "+", flags: [ .command, .shift ]), own: "+"), [ 0x2b ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.c, "c", ignoring: "\u{441}", flags: .command), own: "\u{441}"), [ 0x441 ],
					   "Command-C on Russian is Command and its charactersIgnoringModifiers, not the Command level's 'c'")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.s, "S", ignoring: "s", flags: [ .option, .capsLock ]), own: "S"), [ 0x73 ],
					   "Option-S under Caps Lock on Tongan, whose Option and Caps Lock level is S, as its Caps Lock level is: "
					   + "Alt and s")
	}

	func testAShortcutNeverSendsTheCapitalCapsLockGives() {
		// Through the strings directly: NSEvent.keyEvent lowercases both under Command and Caps Lock, but Hungarian -
		// QWERTY's layout data has the capital there (UCKeyTranslate, Command and Caps Lock), as do more than a
		// thousand other key and layout pairs. No layout's Control level has a character of the key's own: that line
		// is the rule alone.
		func shortcut(_ characters: String, ignoring: String, _ flags: NSEvent.ModifierFlags) -> [UInt32] {
			VNCKeyCode.keyCodesFrom(cgKeyCode: CGKeyCode(Key.a),
									characters: characters,
									charactersIgnoringModifiers: ignoring,
									charactersWithoutDeadKeys: "A",
									modifierFlags: flags).map(\.rawValue)
		}

		XCTAssertEqual(shortcut("A", ignoring: "a", [ .command, .capsLock ]), [ 0x61 ], "Command and a")
		XCTAssertEqual(shortcut("A", ignoring: "a", [ .control, .capsLock ]), [ 0x61 ], "Control and a")
		XCTAssertEqual(shortcut("A", ignoring: "a", [ .option, .capsLock ]), [ 0x61 ], "Alt and a")
	}

	func testAnEmptyCharactersSendsTheCharacterIgnoringModifiers() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.e, "", ignoring: "e", flags: .option), own: "e"), [ 0x65 ],
					   "Option-e, a dead key: characters is empty, as NSEvent documents")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.leftBracket, "", ignoring: "^"), own: "^"), [ 0x5e ],
					   "a dead key with no modifier goes as it did before")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.leftBracket, "", ignoring: "^"), own: ""), [ 0x5e ],
					   "and so it does were the layout's own answer empty too: an empty characters is never the key's own")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "", ignoring: "")), [ ], "a key that types nothing sends nothing")
	}

	func testTheKeyAfterADeadKeySendsTheCharacterIgnoringModifiers() {
		func completing(_ keyCode: UInt16, _ characters: String, ignoring: String, own: String,
						flags: NSEvent.ModifierFlags = [ ]) -> [UInt32] {
			VNCKeyCode.keyCodesFrom(cgKeyCode: CGKeyCode(keyCode),
									characters: characters,
									charactersIgnoringModifiers: ignoring,
									charactersWithoutDeadKeys: own,
									modifierFlags: flags,
									completingDeadKey: true).map(\.rawValue)
		}

		XCTAssertEqual(completing(Key.e, "é", ignoring: "e", own: "e"), [ 0x65 ],
					   "Option-e then e: the server was sent the dead key, and composes; not the accent twice")
		XCTAssertEqual(completing(Key.e, "ê", ignoring: "e", own: "e"), [ 0x65 ], "the '^' dead key, then e")
		XCTAssertEqual(completing(Key.e, "Ê", ignoring: "E", own: "E", flags: .shift), [ 0x45 ], "Shift as it applies")
		XCTAssertEqual(completing(Key.e, "Ê", ignoring: "e", own: "E", flags: .capsLock), [ 0x65 ],
					   "as before: charactersIgnoringModifiers has no Caps Lock")
		XCTAssertEqual(completing(Key.a, "^a", ignoring: "a", own: "a"), [ 0x61 ],
					   "a key the dead key does not compose with: the dead key went on its own")
		XCTAssertEqual(completing(Key.a, "\u{1}", ignoring: "a", own: "a", flags: .control), [ 0x61 ], "a shortcut as ever")
		XCTAssertEqual(completing(Key.leftArrow, "\u{F702}", ignoring: "\u{F702}", own: "\u{F702}", flags: [ .numericPad, .function ]),
					   [ 0xff51 ], "a key with a keysym of its own as ever")
		XCTAssertEqual(completing(Key.b, "B", ignoring: "b", own: "B", flags: .capsLock), [ 0x62 ],
					   "its own capital: Caps Lock does not apply to the key after a dead key")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.b, "B", ignoring: "b", flags: .capsLock)), [ 0x42 ],
					   "not after one (completingDeadKey defaults to false): B")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.e, "é", ignoring: "e"), own: "e"), [ 0x65 ],
					   "with no dead key remembered (it went down in another view): what a pending dead key made "
					   + "of the key is not its own character, so its charactersIgnoringModifiers")
	}

	func testADeadKeyHasNoCharactersButACharacterIgnoringModifiers() {
		XCTAssertTrue(VNCKeyCode.isDeadKey(characters: "", charactersIgnoringModifiers: "e"), "Option-e")
		XCTAssertTrue(VNCKeyCode.isDeadKey(characters: "", charactersIgnoringModifiers: "^"), "French '^'")
		XCTAssertFalse(VNCKeyCode.isDeadKey(characters: "", charactersIgnoringModifiers: ""),
					   "nothing on the level in use (Apple's Hebrew with Shift)")
		XCTAssertFalse(VNCKeyCode.isDeadKey(characters: nil, charactersIgnoringModifiers: nil))
		XCTAssertFalse(VNCKeyCode.isDeadKey(characters: "´", charactersIgnoringModifiers: "E"),
					   "Option-Shift-e: \"the standard accent\", no dead key")
		XCTAssertFalse(VNCKeyCode.isDeadKey(characters: "é", charactersIgnoringModifiers: "e"), "the key that completes one")
		XCTAssertTrue(VNCKeyCode.isDeadKey(characters: "", charactersIgnoringModifiers: "a"),
					  "Estonian Option-A, which types nothing and starts no dead key: Option-e's strings")
		XCTAssertFalse(VNCKeyCode.isDeadKey(characters: "'", charactersIgnoringModifiers: "'"),
					   "US International's second ', which types ' and leaves the first pending")
	}

	func testTheModifierKeyCodes() {
		// kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control, kVK_RightShift, kVK_RightOption,
		// kVK_RightControl, kVK_Function, kVK_RightCommand.
		for keyCode: UInt16 in [ 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x36 ] {
			XCTAssertTrue(VNCKeyCode.isModifier(cgKeyCode: CGKeyCode(keyCode)), "0x\(String(keyCode, radix: 16))")
		}

		for keyCode in [ Key.a, Key.e, Key.space, Key.leftArrow, Key.keypad5, Key.leftBracket, 0x24, 0x33, 0x35 ] {
			XCTAssertFalse(VNCKeyCode.isModifier(cgKeyCode: CGKeyCode(keyCode)), "0x\(String(keyCode, radix: 16))")
		}
	}

	func testAKeyWithAKeysymOfItsOwnIgnoresItsStrings() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.leftArrow, "\u{F702}", ignoring: "\u{F702}",
									 flags: [ .numericPad, .function ])), [ 0xff51 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.leftArrow, "\u{F702}", ignoring: "\u{F702}",
									 flags: [ .numericPad, .function, .shift, .capsLock ])), [ 0xff51 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.space, " ", ignoring: " ", flags: .shift)), [ 0x20 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.keypad5, "5", ignoring: "5", flags: .numericPad)), [ 0x35 ],
					   "a keypad digit has no keysym of its own in the kit's map, so it goes as its character")
	}

	func testAKeyUpWithNoPressSendsTheCharacterIgnoringModifiers() {
		let up = keyEvent(.keyUp, Key.a, "A", ignoring: "a", flags: .capsLock)

		XCTAssertEqual(VNCKeyCode.keyCodesIgnoringModifiersFrom(event: up).map(\.rawValue), [ 0x61 ])
	}

	func testWhereTheLayoutCannotBeAskedTheRuleIsTheOneBefore() {
		// charactersWithoutDeadKeys nil: `characters` where it is charactersIgnoringModifiers or, both ASCII, its capital.
		func sent(_ keyCode: UInt16, _ characters: String, ignoring: String, _ flags: NSEvent.ModifierFlags = [ ]) -> [UInt32] {
			VNCKeyCode.keyCodesFrom(cgKeyCode: CGKeyCode(keyCode),
									characters: characters,
									charactersIgnoringModifiers: ignoring,
									charactersWithoutDeadKeys: nil,
									modifierFlags: flags).map(\.rawValue)
		}

		XCTAssertEqual(sent(Key.a, "A", ignoring: "a", .capsLock), [ 0x41 ], "an ASCII capital")
		XCTAssertEqual(sent(Key.a, "a", ignoring: "a"), [ 0x61 ])
		XCTAssertEqual(sent(Key.two, "\u{C9}", ignoring: "\u{E9}", .capsLock), [ 0xe9 ], "French É: é, as before")
		XCTAssertEqual(sent(Key.h, "h", ignoring: "\u{5D9}", .capsLock), [ 0x5d9 ], "Hebrew's h: the Hebrew letter, as before")
		XCTAssertEqual(sent(Key.semicolon, "';", ignoring: ";"), [ 0x3b ], "a pending accent: ;")
		XCTAssertEqual(sent(Key.e, "", ignoring: "e", .option), [ 0x65 ], "a dead key")
		XCTAssertEqual(sent(Key.a, "", ignoring: ""), [ ])
	}
}

/// What a key types at its event's Shift and Caps Lock alone, with no dead key pending -- the view's question,
/// VNCKeyCode.charactersWithoutDeadKeys -- on Apple's layouts, read by ID and never selected, at an ANSI keyboard's
/// type (40); and on this Mac's current layout, checked against that layout's data translated here, since the
/// current layout is whatever this Mac has.
final class MacKeyCharactersWithoutDeadKeysTests: XCTestCase {
	private func types(_ layout: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) throws -> String? {
		let bytes = try layoutData(id: "com.apple.keylayout." + layout)

		return bytes.withUnsafeBytes { buffer in
			VNCKeyCode.charactersWithoutDeadKeys(cgKeyCode: CGKeyCode(keyCode),
												 modifierFlags: flags,
												 keyboardLayout: buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
												 keyboardType: 40)
		}
	}

	func testItIsWhatTheLayoutTypesAtShiftAndCapsLock() throws {
		XCTAssertEqual(try types("US", Key.a, [ ]), "a")
		XCTAssertEqual(try types("US", Key.a, .shift), "A")
		XCTAssertEqual(try types("US", Key.a, .capsLock), "A")
		XCTAssertEqual(try types("US", Key.a, [ .capsLock, .shift ]), "A")
		XCTAssertEqual(try types("Hebrew", Key.h, [ ]), "\u{5D9}")
		XCTAssertEqual(try types("Hebrew", Key.h, .capsLock), "h", "Apple's Hebrew types English at Caps Lock")
		XCTAssertEqual(try types("Hebrew", Key.h, [ .capsLock, .shift ]), "H")
		XCTAssertEqual(try types("Hebrew", Key.h, .shift), "", "and nothing at Shift alone")
		XCTAssertEqual(try types("Hebrew-PC", Key.h, .capsLock), "H")
		XCTAssertEqual(try types("Hebrew-PC", Key.h, [ .capsLock, .shift ]), "\u{5D9}")
		XCTAssertEqual(try types("Hebrew-QWERTY", Key.two, .capsLock), "\u{201C}")
		XCTAssertEqual(try types("Arabic", Key.one, [ ]), "\u{661}")
		XCTAssertEqual(try types("Arabic", Key.one, .capsLock), "1")
		XCTAssertEqual(try types("French-numerical", Key.one, [ ]), "&")
		XCTAssertEqual(try types("French-numerical", Key.one, .capsLock), "1")
		XCTAssertEqual(try types("French-numerical", Key.a, [ .capsLock, .shift ]), "q", "the A key is Q on AZERTY")
		XCTAssertEqual(try types("Georgian-QWERTY", Key.h, .capsLock), "h")
		XCTAssertEqual(try types("French", Key.two, .capsLock), "\u{C9}")
		XCTAssertEqual(try types("German", Key.quote, .capsLock), "\u{C4}")
		XCTAssertEqual(try types("Spanish-ISO", Key.semicolon, .capsLock), "\u{D1}")
		XCTAssertEqual(try types("Turkish-QWERTY-PC", Key.quote, .capsLock), "\u{130}")
		XCTAssertEqual(try types("Turkish-QWERTY-PC", Key.i, .capsLock), "I")
	}

	func testADeadKeyAnswersWithItsOwnCharacter() throws {
		XCTAssertEqual(try types("French", Key.leftBracket, [ ]), "^", "the '^' dead key, its own character, not nothing")
		XCTAssertEqual(try types("French", Key.leftBracket, .capsLock), "^")
		XCTAssertEqual(try types("USInternational-PC", Key.quote, [ ]), "'")
		XCTAssertEqual(try types("USInternational-PC", Key.quote, .shift), "\"")
		XCTAssertEqual(try types("Czech-QWERTY", Key.equal, .shift), "\u{2C7}", "Shift-´, the ˇ dead key")
	}

	func testCommandControlAndOptionAreNotApplied() throws {
		XCTAssertEqual(try types("US", Key.a, [ .option, .capsLock ]), "A", "not Option and Caps Lock's Å")
		XCTAssertEqual(try types("US", Key.e, .option), "e", "not the Option-e dead key")
		XCTAssertEqual(try types("US", Key.a, [ .command, .shift ]), "A")
		XCTAssertEqual(try types("US", Key.a, .control), "a", "not U+0001")
		XCTAssertEqual(try types("Estonian", Key.a, [ .option, .capsLock ]), "A", "not ū")
		XCTAssertEqual(try types("US", Key.a, [ .numericPad, .function ]), "a")
	}

	func testTheEventsAskTheCurrentLayout() throws {
		let flagsList: [NSEvent.ModifierFlags] = [
			[ ], .shift, .capsLock, [ .shift, .capsLock ],
			.option, [ .option, .capsLock ], [ .option, .shift ], .command, [ .command, .capsLock ], .control,
			[ .control, .shift, .capsLock ], .numericPad, .function
		]

		for keyCode in [ Key.a, Key.h, Key.e, Key.one, Key.two, Key.quote, Key.semicolon, Key.equal, Key.leftBracket ] {
			for flags in flagsList {
				let event = keyEvent(.keyDown, keyCode, "", ignoring: "", flags: flags)
				let expected = try currentLayoutTypes(keyCode, shift: flags.contains(.shift), capsLock: flags.contains(.capsLock))

				XCTAssertEqual(VNCKeyCode.charactersWithoutDeadKeys(of: event), expected,
							   "key 0x\(String(keyCode, radix: 16)), flags 0x\(String(flags.rawValue, radix: 16))")
			}
		}
	}
}

/// What each key sent going down, by its key code, and under which Shift: HeldKeyCodes.
final class HeldKeyCodesTests: XCTestCase {
	private let lowerA = [ VNCKeyCode(0x61) ], upperA = [ VNCKeyCode(0x41) ]

	func testAKeyComesUpAsItWentDownAndIsForgotten() {
		var held = HeldKeyCodes()

		let down = held.keyDown(Key.a, isARepeat: false, shift: false) { self.upperA }

		XCTAssertEqual(down.released, [ ])
		XCTAssertEqual(down.pressed, upperA)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, upperA, "its press, not what it types now")
		XCTAssertTrue(held.isEmpty)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, lowerA, "a second key-up was never pressed: the fallback")
	}

	func testARepeatThatSendsWhatThePressSentResendsIt() {
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false, shift: false) { self.lowerA }

		let repeated = held.keyDown(Key.a, isARepeat: true, shift: false) { self.lowerA }

		XCTAssertEqual(repeated.released, [ ])
		XCTAssertEqual(repeated.pressed, lowerA)
		XCTAssertEqual(held.keyUp(Key.a) { self.upperA }, lowerA)
		XCTAssertTrue(held.isEmpty)
	}

	func testARepeatThatSendsOtherKeysLetsGoOfThePressAndPressesThem() {
		// 'a' held, Shift pressed mid-repeat: 'A'.
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false, shift: false) { self.lowerA }

		let repeated = held.keyDown(Key.a, isARepeat: true, shift: true) { self.upperA }

		XCTAssertEqual(repeated.released, lowerA, "what the press sent, which the server holds")
		XCTAssertEqual(repeated.pressed, upperA, "what the key types now")

		let again = held.keyDown(Key.a, isARepeat: true, shift: true) { self.upperA }

		XCTAssertEqual(again.released, [ ], "the next repeat, unchanged since -- its keys and its Shift -- re-sends it")
		XCTAssertEqual(again.pressed, upperA)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, upperA, "the key-up lets go of what the last repeat sent")
		XCTAssertTrue(held.isEmpty)
	}

	func testARepeatOfTheSameKeysUnderAnotherShiftLetsGoOfThemAndPressesThemAgain() {
		// Caps Lock on, 'A' held with Shift, Shift let go mid-repeat: the key types 'A' still. A server presses a held key
		// again at a repeat under the Shift it holds then, which no longer makes the capital; pressed anew, it is decided by
		// its keysym.
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false, shift: true) { self.upperA }

		let same = held.keyDown(Key.a, isARepeat: true, shift: true) { self.upperA }

		XCTAssertEqual(same.released, [ ], "the keys and the Shift they went down under: re-sent")
		XCTAssertEqual(same.pressed, upperA)

		let shiftLetGo = held.keyDown(Key.a, isARepeat: true, shift: false) { self.upperA }

		XCTAssertEqual(shiftLetGo.released, upperA, "the same keys under another Shift: let go of")
		XCTAssertEqual(shiftLetGo.pressed, upperA, "and pressed again")

		let again = held.keyDown(Key.a, isARepeat: true, shift: false) { self.upperA }

		XCTAssertEqual(again.released, [ ], "the next repeat, under the Shift remembered now: re-sent")
		XCTAssertEqual(again.pressed, upperA)

		let shiftPressed = held.keyDown(Key.a, isARepeat: true, shift: true) { self.upperA }

		XCTAssertEqual(shiftPressed.released, upperA, "Shift pressed again: let go of and pressed again")
		XCTAssertEqual(shiftPressed.pressed, upperA)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, upperA)
		XCTAssertTrue(held.isEmpty)
	}

	func testANewPressIsRememberedWithItsOwnShift() {
		// A press of a key still held (its key-up never came) is remembered under its own Shift, not the old press's.
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false, shift: false) { self.upperA }

		let pressedAgain = held.keyDown(Key.a, isARepeat: false, shift: true) { self.upperA }

		XCTAssertEqual(pressedAgain.released, upperA, "its key-up never came: let go of first, as ever")
		XCTAssertEqual(pressedAgain.pressed, upperA)

		let repeated = held.keyDown(Key.a, isARepeat: true, shift: true) { self.upperA }

		XCTAssertEqual(repeated.released, [ ], "a repeat under the new press's Shift: re-sent")
		XCTAssertEqual(repeated.pressed, upperA)
	}

	func testARepeatOfAKeyNeverSeenGoingDownIsAPress() {
		var held = HeldKeyCodes()

		let repeated = held.keyDown(Key.a, isARepeat: true, shift: false) { self.upperA }

		XCTAssertEqual(repeated.released, [ ])
		XCTAssertEqual(repeated.pressed, upperA)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, upperA)
	}

	func testAPressOfAKeyStillHeldLetsGoOfThatPressFirst() {
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false, shift: false) { self.upperA }

		let again = held.keyDown(Key.a, isARepeat: false, shift: false) { self.lowerA }

		XCTAssertEqual(again.released, upperA, "its key-up never came: the server still holds it")
		XCTAssertEqual(again.pressed, lowerA)
		XCTAssertEqual(held.keyUp(Key.a) { self.upperA }, lowerA)
		XCTAssertTrue(held.isEmpty)
	}

	func testAKeyThatSentNothingComesUpAsNothing() {
		var held = HeldKeyCodes()

		XCTAssertEqual(held.keyDown(Key.a, isARepeat: false, shift: false) { [ ] }.pressed, [ ])
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, [ ], "not a key-up for something never pressed")
	}

	func testKeysAreRememberedApart() {
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false, shift: false) { self.upperA }
		_ = held.keyDown(Key.e, isARepeat: false, shift: false) { [ VNCKeyCode(0x65) ] }

		XCTAssertEqual(held.keyUp(Key.a) { [ ] }, upperA)
		XCTAssertEqual(held.keyUp(Key.e) { [ ] }, [ VNCKeyCode(0x65) ])
		XCTAssertTrue(held.isEmpty)
	}
}

/// The view itself: its keyDown(with:), keyUp(with:) and flagsChanged(with:), and the KeyEvents
/// they queue on a connection that never connects.
final class MacFramebufferViewKeyboardTests: XCTestCase {
	private final class Delegate: NSObject, VNCConnectionDelegate {
		func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) { }

		func connection(_ connection: VNCConnection,
						credentialFor authenticationType: VNCAuthenticationType,
						completion: @escaping (VNCCredential?) -> Void) {
			completion(nil)
		}

		func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) { }
		func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) { }

		func connection(_ connection: VNCConnection,
						didUpdateFramebuffer framebuffer: VNCFramebuffer,
						x: UInt16, y: UInt16,
						width: UInt16, height: UInt16) { }

		func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) { }
	}

	private let delegate = Delegate()
	private var connection: VNCConnection!
	private var framebuffer: VNCFramebuffer!
	private var view: VNCCAFramebufferView!

	override func setUpWithError() throws {
		// Never connected: the hostname is never looked up or dialled.
		let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
											  hostname: "127.0.0.1",
											  port: 5900,
											  isShared: true,
											  isScalingEnabled: true,
											  useDisplayLink: false,
											  inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
											  isClipboardRedirectionEnabled: false,
											  colorDepth: .depth24Bit,
											  frameEncodings: VNCFrameEncodingType.defaultFrameEncodings)

		let connection = VNCConnection(settings: settings, logger: VNCPrintLogger())

		framebuffer = try VNCFramebuffer(logger: connection.logger,
										 size: .init(width: 8, height: 8),
										 screens: [ ],
										 pixelFormat: .init(depth: 24),
										 allocator: nil)

		view = VNCCAFramebufferView(frame: .init(x: 0, y: 0, width: 8, height: 8),
									framebuffer: framebuffer,
									connection: connection,
									connectionDelegate: delegate)

		self.connection = connection
	}

	override func tearDown() {
		view = nil
		framebuffer = nil
		connection = nil
	}

	/// The KeyEvents queued since the last call.
	private func sent() -> [String] {
		var keys = [String]()

		while let message = connection.clientToServerMessageQueue.dequeue() {
			guard let key = message as? VNCProtocol.KeyEvent else { continue }

			keys.append("\(key.isDown ? "down" : "up") 0x\(String(key.key, radix: 16))")
		}

		return keys
	}

	/// A key-down whose key types `own` at its Shift and Caps Lock with no dead key pending -- by default its
	/// `characters` -- which the view is given in place of asking this Mac's current layout.
	private func down(_ keyCode: UInt16, _ characters: String, ignoring: String, own: String? = nil,
					  flags: NSEvent.ModifierFlags = [ ], repeat isARepeat: Bool = false) {
		view.charactersWithoutDeadKeys = { _ in own ?? characters }
		view.keyDown(with: keyEvent(.keyDown, keyCode, characters, ignoring: ignoring, flags: flags, repeat: isARepeat))
	}

	private func up(_ keyCode: UInt16, _ characters: String, ignoring: String, own: String? = nil,
					flags: NSEvent.ModifierFlags = [ ]) {
		view.charactersWithoutDeadKeys = { _ in own ?? characters }
		view.keyUp(with: keyEvent(.keyUp, keyCode, characters, ignoring: ignoring, flags: flags))
	}

	private func flags(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
		view.flagsChanged(with: keyEvent(.flagsChanged, keyCode, "", ignoring: "", flags: flags))
	}

	func testTheViewAsksTheCurrentLayoutWhatAKeyTypesAtItsShiftAndCapsLock() throws {
		// Before any test answer is given: the view's own question, VNCKeyCode.charactersWithoutDeadKeys(of:).
		let event = keyEvent(.keyDown, Key.a, "", ignoring: "", flags: [ .capsLock, .option ])

		XCTAssertEqual(view.charactersWithoutDeadKeys(event), try currentLayoutTypes(Key.a, shift: false, capsLock: true))
	}

	func testCapsLockTypesCapitalsAndIsNotSentItself() {
		flags(Key.capsLock, .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x41", "up 0x41" ])
	}

	func testAKeyLetGoAfterShiftComesUpAsItWentDown() {
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.minus, "_", ignoring: "_", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])
		up(Key.minus, "-", ignoring: "-")

		XCTAssertEqual(sent(), [ "down 0xffe1", "down 0x5f", "up 0xffe1", "up 0x5f" ],
					   "'_' down and '_' up, not '-' up with '_' left held")
	}

	func testAShortcutLetGoAfterShiftComesUpAsItWentDown() {
		// Command-Shift-= (Command-+ on a US layout), Shift and Command let go before the key.
		flags(Key.command, [ .command, .leftCommand ])
		flags(Key.shift, [ .command, .leftCommand, .shift, .leftShift ])
		down(Key.equal, "+", ignoring: "+", flags: [ .command, .leftCommand, .shift, .leftShift ])
		flags(Key.shift, [ .command, .leftCommand ])
		flags(Key.command, [ ])
		up(Key.equal, "=", ignoring: "=")

		XCTAssertEqual(sent(), [ "down 0xffeb", "down 0xffe1", "down 0x2b", "up 0xffe1", "up 0xffeb", "up 0x2b" ])
	}

	func testALetterLetGoAfterShiftComesUpAsItWentDownOnTurkishQ() {
		// Turkish Q: 'i' and, with Shift, 'İ' on one key. The kit's withCharacter sends 'İ' as its
		// bare code point, 0x130, which no press made.
		down(Key.quote, "i", ignoring: "i")
		flags(Key.shift, [ .shift, .leftShift ])
		up(Key.quote, "İ", ignoring: "İ", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])

		XCTAssertEqual(sent(), [ "down 0x69", "down 0xffe1", "up 0x69", "up 0xffe1" ])
	}

	func testARepeatThatTypesWhatItsPressDidResendsIt() {
		down(Key.h, "h", ignoring: "h")
		down(Key.h, "h", ignoring: "h", repeat: true)
		up(Key.h, "h", ignoring: "h")

		XCTAssertEqual(sent(), [ "down 0x68", "down 0x68", "up 0x68" ])
	}

	func testARepeatAfterShiftChangesSendsWhatTheKeyTypesNow() {
		// '-' held until it repeats, then Shift: the Mac types '_' from then on, and so does the server.
		down(Key.minus, "-", ignoring: "-")
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.minus, "_", ignoring: "_", flags: [ .shift, .leftShift ], repeat: true)
		down(Key.minus, "_", ignoring: "_", flags: [ .shift, .leftShift ], repeat: true)
		up(Key.minus, "_", ignoring: "_", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])

		XCTAssertEqual(sent(), [ "down 0x2d", "down 0xffe1", "up 0x2d", "down 0x5f", "down 0x5f", "up 0x5f", "up 0xffe1" ])
	}

	func testARepeatAfterShiftIsLetGoSendsWhatTheKeyTypesNow() {
		// 'H' held with Shift, Shift let go mid-repeat: the repeats are 'h', and the key-up lets go of 'h'.
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.h, "H", ignoring: "H", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])
		down(Key.h, "h", ignoring: "h", repeat: true)
		up(Key.h, "h", ignoring: "h")

		XCTAssertEqual(sent(), [ "down 0xffe1", "down 0x48", "up 0xffe1", "up 0x48", "down 0x68", "up 0x68" ])
	}

	func testAPressWhoseKeyUpNeverCameIsLetGoOfFirst() {
		down(Key.a, "A", ignoring: "A", flags: .shift)
		// Its key-up went elsewhere (focus moved, or AppKit kept it back); the key is pressed again.
		down(Key.a, "a", ignoring: "a")
		up(Key.a, "a", ignoring: "a")

		XCTAssertEqual(sent(), [ "down 0x41", "up 0x41", "down 0x61", "up 0x61" ])
	}

	func testAKeyUpWithNoPressSendsItsCharacterIgnoringModifiersAsBefore() {
		up(Key.a, "A", ignoring: "a", flags: .capsLock)

		XCTAssertEqual(sent(), [ "up 0x61" ])
	}

	func testDeadKeysGoAsBefore() {
		// Option-e on a US layout, and the '^' dead key of a French one: characters is empty.
		flags(0x3a, [ .option, .leftOption ])
		down(Key.e, "", ignoring: "e", own: "e", flags: [ .option, .leftOption ])
		up(Key.e, "", ignoring: "e", own: "e", flags: [ .option, .leftOption ])
		flags(0x3a, [ ])
		down(Key.leftBracket, "", ignoring: "^", own: "^")
		up(Key.leftBracket, "", ignoring: "^", own: "^")

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x65", "up 0x65", "up 0xffe9", "down 0x5e", "up 0x5e" ])
	}

	func testTheKeyAfterADeadKeyGoesAsBefore() {
		// Option-e then e: AppKit composes 'é' into the e key's characters; the server, sent Option and
		// e, composes for itself.
		flags(0x3a, [ .option, .leftOption ])
		down(Key.e, "", ignoring: "e", own: "e", flags: [ .option, .leftOption ])
		up(Key.e, "", ignoring: "e", own: "e", flags: [ .option, .leftOption ])
		flags(0x3a, [ ])
		down(Key.e, "é", ignoring: "e", own: "e")
		up(Key.e, "é", ignoring: "e", own: "e")
		// The French '^' dead key, then e: '^' and e, not '^' and 'ê'.
		down(Key.leftBracket, "", ignoring: "^", own: "^")
		up(Key.leftBracket, "", ignoring: "^", own: "^")
		down(Key.e, "ê", ignoring: "e", own: "e")
		up(Key.e, "ê", ignoring: "e", own: "e")

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x65", "up 0x65", "up 0xffe9", "down 0x65", "up 0x65",
								 "down 0x5e", "up 0x5e", "down 0x65", "up 0x65" ])
	}

	func testAModifierBetweenADeadKeyAndItsKeyLeavesItTheKeyAfter() {
		// '^', then Shift, then E: 'E', Shift applied, not 'Ê'.
		down(Key.leftBracket, "", ignoring: "^", own: "^")
		up(Key.leftBracket, "", ignoring: "^", own: "^")
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.e, "Ê", ignoring: "E", own: "E", flags: [ .shift, .leftShift ])
		up(Key.e, "Ê", ignoring: "E", own: "E", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])

		XCTAssertEqual(sent(), [ "down 0x5e", "up 0x5e", "down 0xffe1", "down 0x45", "up 0x45", "up 0xffe1" ])
	}

	func testOnlyTheOneKeyAfterADeadKeyGoesAsBefore() {
		// '^' then e, then a with Caps Lock: 'A', what it types.
		down(Key.leftBracket, "", ignoring: "^", own: "^")
		up(Key.leftBracket, "", ignoring: "^", own: "^")
		down(Key.e, "ê", ignoring: "e", own: "e")
		up(Key.e, "ê", ignoring: "e", own: "e")
		down(Key.a, "A", ignoring: "a", flags: .capsLock)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)

		XCTAssertEqual(sent(), [ "down 0x5e", "up 0x5e", "down 0x65", "up 0x65", "down 0x41", "up 0x41" ])
	}

	func testAKeyWithAKeysymOfItsOwnEndsADeadKey() {
		// '^', the left arrow, then a with Caps Lock: 'A'.
		down(Key.leftBracket, "", ignoring: "^", own: "^")
		up(Key.leftBracket, "", ignoring: "^", own: "^")
		down(Key.leftArrow, "\u{F702}", ignoring: "\u{F702}", flags: [ .numericPad, .function ])
		up(Key.leftArrow, "\u{F702}", ignoring: "\u{F702}", flags: [ .numericPad, .function ])
		down(Key.a, "A", ignoring: "a", flags: .capsLock)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)

		XCTAssertEqual(sent(), [ "down 0x5e", "up 0x5e", "down 0xff51", "up 0xff51", "down 0x41", "up 0x41" ])
	}

	func testARepeatOfADeadKeyLeavesTheKeyAfterIt() {
		// '^' held until it repeats: the repeat re-sends the press, and the e after it is still the key after.
		down(Key.leftBracket, "", ignoring: "^", own: "^")
		down(Key.leftBracket, "", ignoring: "^", own: "^", repeat: true)
		up(Key.leftBracket, "", ignoring: "^", own: "^")
		down(Key.e, "ê", ignoring: "e", own: "e")
		up(Key.e, "ê", ignoring: "e", own: "e")

		XCTAssertEqual(sent(), [ "down 0x5e", "down 0x5e", "up 0x5e", "down 0x65", "up 0x65" ])
	}

	func testTwoDeadKeysInARowSendTheAccentOnce() {
		// US International - PC: ' ' ; types "'';" -- the first ' a dead key, the second typing ' with the first
		// still pending, ; then typing "';" -- and ; held repeats as ;.
		down(Key.quote, "", ignoring: "'", own: "'")
		up(Key.quote, "", ignoring: "'", own: "'")
		down(Key.quote, "'", ignoring: "'")
		up(Key.quote, "'", ignoring: "'")
		down(Key.semicolon, "';", ignoring: ";", own: ";")
		down(Key.semicolon, ";", ignoring: ";", repeat: true)
		up(Key.semicolon, ";", ignoring: ";")

		XCTAssertEqual(sent(), [ "down 0x27", "up 0x27", "down 0x27", "up 0x27", "down 0x3b", "down 0x3b", "up 0x3b" ],
					   "' ' ; ;, not the accent again with each ;")
	}

	func testTwoShiftedDeadKeysInARowSendTheAccentOnce() {
		// US International - PC: " " ) types "\"\")".
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.quote, "", ignoring: "\"", own: "\"", flags: [ .shift, .leftShift ])
		up(Key.quote, "", ignoring: "\"", own: "\"", flags: [ .shift, .leftShift ])
		down(Key.quote, "\"", ignoring: "\"", flags: [ .shift, .leftShift ])
		up(Key.quote, "\"", ignoring: "\"", flags: [ .shift, .leftShift ])
		down(Key.zero, "\")", ignoring: ")", own: ")", flags: [ .shift, .leftShift ])
		up(Key.zero, "\")", ignoring: ")", own: ")", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])

		XCTAssertEqual(sent(), [ "down 0xffe1", "down 0x22", "up 0x22", "down 0x22", "up 0x22", "down 0x29", "up 0x29", "up 0xffe1" ])
	}

	func testTwoDeadKeysInARowThenALetterTheyComposeWith() {
		// US International - PC: ' ' e types "'é". ' ' e, as before.
		down(Key.quote, "", ignoring: "'", own: "'")
		up(Key.quote, "", ignoring: "'", own: "'")
		down(Key.quote, "'", ignoring: "'")
		up(Key.quote, "'", ignoring: "'")
		down(Key.e, "é", ignoring: "e", own: "e")
		up(Key.e, "é", ignoring: "e", own: "e")

		XCTAssertEqual(sent(), [ "down 0x27", "up 0x27", "down 0x27", "up 0x27", "down 0x65", "up 0x65" ])
	}

	func testCapsLockBeyondLatin1GoesAsBeforeAndWithinItAsItTypes() {
		// Caps Lock on: Turkish Q's i key types İ, which goes as before, i -- İ's bare code point, 0x130, is no keysym
		// for it; a French layout's é key types É, and the A key A, which go as themselves.
		flags(Key.capsLock, .capsLock)
		down(Key.quote, "İ", ignoring: "i", flags: .capsLock)
		up(Key.quote, "İ", ignoring: "i", flags: .capsLock)
		down(Key.two, "É", ignoring: "é", flags: .capsLock)
		up(Key.two, "É", ignoring: "é", flags: .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x69", "up 0x69", "down 0xc9", "up 0xc9", "down 0x41", "up 0x41" ])
	}

	func testCapsLockOnHebrewTypesItsEnglishLetters() {
		// Apple's Hebrew types English at Caps Lock: h, held until it repeats, and with Shift too, H -- where Shift
		// alone types nothing. Neither is the Hebrew letter the key's charactersIgnoringModifiers is.
		flags(Key.capsLock, .capsLock)
		down(Key.h, "h", ignoring: "\u{5D9}", flags: .capsLock)
		down(Key.h, "h", ignoring: "\u{5D9}", flags: .capsLock, repeat: true)
		up(Key.h, "h", ignoring: "\u{5D9}", flags: .capsLock)
		flags(Key.shift, [ .capsLock, .shift, .leftShift ])
		down(Key.h, "H", ignoring: "", flags: [ .capsLock, .shift, .leftShift ])
		up(Key.h, "H", ignoring: "", flags: [ .capsLock, .shift, .leftShift ])
		flags(Key.shift, .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x68", "down 0x68", "up 0x68", "down 0xffe1", "down 0x48", "up 0x48", "up 0xffe1" ])
	}

	func testARepeatUnderCapsLockSendsTheCapitalAgain() {
		flags(Key.capsLock, .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock, repeat: true)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x41", "down 0x41", "up 0x41" ],
					   "the repeat as what the key types, A -- not its charactersIgnoringModifiers, a")
	}

	func testCapsLockTurnedOnMidRepeatSendsTheCapital() {
		down(Key.a, "a", ignoring: "a")
		flags(Key.capsLock, .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock, repeat: true)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x61", "up 0x61", "down 0x41", "up 0x41" ])
	}

	func testCapsLockOnAndShiftLetGoMidRepeatPressesTheCapitalAgain() {
		// Caps Lock on, Shift and A held, Shift let go mid-repeat: the Mac goes on typing A. The repeat's keysym is the same
		// and its Shift is not, so 'A' is let go of and pressed again: a new press, which a server decides by its keysym,
		// where its held key pressed again with no Shift would type a.
		flags(Key.capsLock, .capsLock)
		flags(Key.shift, [ .capsLock, .shift, .leftShift ])
		down(Key.a, "A", ignoring: "A", flags: [ .capsLock, .shift, .leftShift ])
		down(Key.a, "A", ignoring: "A", flags: [ .capsLock, .shift, .leftShift ], repeat: true)
		flags(Key.shift, .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock, repeat: true)
		down(Key.a, "A", ignoring: "a", flags: .capsLock, repeat: true)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0xffe1", "down 0x41", "down 0x41", "up 0xffe1", "up 0x41", "down 0x41", "down 0x41",
								 "up 0x41" ])
	}

	func testCapsLockOnAndShiftPressedMidRepeatPressesTheCapitalAgain() {
		// Caps Lock on, A held, Shift pressed mid-repeat: Caps Lock and Shift type A on a Mac. A server whose own Caps Lock is
		// on would type its held key pressed again under Shift as a.
		flags(Key.capsLock, .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock, repeat: true)
		flags(Key.shift, [ .capsLock, .shift, .leftShift ])
		down(Key.a, "A", ignoring: "A", flags: [ .capsLock, .shift, .leftShift ], repeat: true)
		up(Key.a, "A", ignoring: "A", flags: [ .capsLock, .shift, .leftShift ])
		flags(Key.shift, .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x41", "down 0x41", "down 0xffe1", "up 0x41", "down 0x41", "up 0x41", "up 0xffe1" ])
	}

	func testCapsLockTurnedOnMidRepeatOfAKeyItLeavesAloneReSendsIt() {
		// '1' held while Caps Lock goes on: the key types '1' still, and a server never sees Caps Lock -- re-sent, not let go
		// of and pressed again.
		down(Key.one, "1", ignoring: "1")
		flags(Key.capsLock, .capsLock)
		down(Key.one, "1", ignoring: "1", flags: .capsLock, repeat: true)
		up(Key.one, "1", ignoring: "1", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x31", "down 0x31", "up 0x31" ])
	}

	func testARepeatOfTheKeyAfterADeadKeyIsNotItsOwn() {
		// The French '^' then e, held under Caps Lock: the e goes as the key after a dead key, e, and its repeat --
		// whose characters are "Ê" again -- is no character of its own either, and re-sends e.
		flags(Key.capsLock, .capsLock)
		down(Key.leftBracket, "", ignoring: "^", own: "^", flags: .capsLock)
		up(Key.leftBracket, "", ignoring: "^", own: "^", flags: .capsLock)
		down(Key.e, "Ê", ignoring: "e", own: "E", flags: .capsLock)
		down(Key.e, "Ê", ignoring: "e", own: "E", flags: .capsLock, repeat: true)
		up(Key.e, "Ê", ignoring: "e", own: "E", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0x5e", "up 0x5e", "down 0x65", "down 0x65", "up 0x65" ])
	}

	func testAKeyThatTypesNothingAtTheOptionLevelIsADeadKeyToTheView() {
		// Estonian: Option-A types nothing and starts no dead key, but its strings are Option-e's ("" and "a"). The
		// key after it, B with Caps Lock on, goes as its charactersIgnoringModifiers: b, without Caps Lock.
		flags(Key.option, [ .option, .leftOption ])
		down(Key.a, "", ignoring: "a", own: "a", flags: [ .option, .leftOption ])
		up(Key.a, "", ignoring: "a", own: "a", flags: [ .option, .leftOption ])
		flags(Key.option, [ ])
		flags(Key.capsLock, .capsLock)
		down(Key.b, "B", ignoring: "b", flags: .capsLock)
		up(Key.b, "B", ignoring: "b", flags: .capsLock)

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x61", "up 0x61", "up 0xffe9", "down 0x62", "up 0x62" ])
	}

	func testAModifierTappedBetweenADeadKeyAndTheKeyAfterLeavesItTheKeyAfter() {
		// As above, with Shift pressed and let go before Caps Lock: b still.
		flags(Key.option, [ .option, .leftOption ])
		down(Key.a, "", ignoring: "a", own: "a", flags: [ .option, .leftOption ])
		up(Key.a, "", ignoring: "a", own: "a", flags: [ .option, .leftOption ])
		flags(Key.option, [ ])
		flags(Key.shift, [ .shift, .leftShift ])
		flags(Key.shift, [ ])
		flags(Key.capsLock, .capsLock)
		down(Key.b, "B", ignoring: "b", flags: .capsLock)
		up(Key.b, "B", ignoring: "b", flags: .capsLock)

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x61", "up 0x61", "up 0xffe9", "down 0xffe1", "up 0xffe1",
								 "down 0x62", "up 0x62" ])
	}

	func testARepeatLeavesTheDeadKeyBookkeepingAlone() {
		// Estonian Option-A held while Caps Lock goes on: its repeat types ū, and is still Alt and a. A repeat is no
		// new key: B after it is still the key after a dead key, b.
		flags(Key.option, [ .option, .leftOption ])
		down(Key.a, "", ignoring: "a", own: "a", flags: [ .option, .leftOption ])
		flags(Key.capsLock, [ .option, .leftOption, .capsLock ])
		down(Key.a, "\u{16B}", ignoring: "a", own: "A", flags: [ .option, .leftOption, .capsLock ], repeat: true)
		up(Key.a, "\u{16B}", ignoring: "a", own: "A", flags: [ .option, .leftOption, .capsLock ])
		flags(Key.option, .capsLock)
		down(Key.b, "B", ignoring: "b", flags: .capsLock)
		up(Key.b, "B", ignoring: "b", flags: .capsLock)

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x61", "down 0x61", "up 0x61", "up 0xffe9", "down 0x62", "up 0x62" ])
	}

	func testARepeatIsNotTheKeyAfterADeadKey() {
		// Estonian: Option-A types nothing and leaves no dead key pending (its layout data), so it is a dead key to the
		// view. Held while Option is let go and Caps Lock goes on, the A key repeats as what it types then, A: a repeat
		// is worked out as a key of its own, not as the key after a dead key (which would send a).
		flags(Key.option, [ .option, .leftOption ])
		down(Key.a, "", ignoring: "a", own: "a", flags: [ .option, .leftOption ])
		flags(Key.option, [ ])
		flags(Key.capsLock, .capsLock)
		down(Key.a, "A", ignoring: "a", flags: .capsLock, repeat: true)
		up(Key.a, "A", ignoring: "a", flags: .capsLock)
		flags(Key.capsLock, [ ])

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x61", "up 0xffe9", "up 0x61", "down 0x41", "up 0x41" ])
	}

	func testAKeyWithNothingOnItsLevelIsNoDeadKey() {
		// Apple's Hebrew, Shift on a letter key: nothing. Then a with Caps Lock: 'A'.
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.a, "", ignoring: "", flags: [ .shift, .leftShift ])
		up(Key.a, "", ignoring: "", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])
		down(Key.e, "E", ignoring: "e", flags: .capsLock)
		up(Key.e, "E", ignoring: "e", flags: .capsLock)

		XCTAssertEqual(sent(), [ "down 0xffe1", "up 0xffe1", "down 0x45", "up 0x45" ])
	}

	func testAKeyThatTypedNothingComesUpAsNothing() {
		// Apple's Hebrew layout types nothing with Shift on most letter keys; Shift let go first.
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.a, "", ignoring: "", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])
		up(Key.a, "ש", ignoring: "ש")

		XCTAssertEqual(sent(), [ "down 0xffe1", "up 0xffe1" ], "no key-up for a letter never pressed")
	}

	func testKeysWithAKeysymOfTheirOwn() {
		down(Key.leftArrow, "\u{F702}", ignoring: "\u{F702}", flags: [ .numericPad, .function ])
		up(Key.leftArrow, "\u{F702}", ignoring: "\u{F702}", flags: [ .numericPad, .function ])
		down(Key.keypad5, "5", ignoring: "5", flags: .numericPad)
		up(Key.keypad5, "5", ignoring: "5", flags: .numericPad)

		XCTAssertEqual(sent(), [ "down 0xff51", "up 0xff51", "down 0x35", "up 0x35" ])
	}
}
#endif
