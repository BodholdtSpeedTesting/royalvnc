#if os(macOS)
// The Mac framebuffer view's keyboard: which of a key event's strings a key sends, and that a key
// comes up as exactly what it went down as.
//
// Key events are made with NSEvent.keyEvent(with:...) and handed to the code directly -- the
// view's own keyDown(with:), keyUp(with:) and flagsChanged(with:) -- and never posted. The view
// has no window, and its connection never connects: what it would send is read off the
// connection's send queue. Key codes are Events.h's kVK_ constants.

import XCTest
import AppKit
@testable import RoyalVNCKit

private enum Key {
	static let a: UInt16 = 0x00            // kVK_ANSI_A
	static let e: UInt16 = 0x0e            // kVK_ANSI_E
	static let two: UInt16 = 0x13          // kVK_ANSI_2: 'é' on a French layout
	static let equal: UInt16 = 0x18        // kVK_ANSI_Equal
	static let minus: UInt16 = 0x1b        // kVK_ANSI_Minus
	static let leftBracket: UInt16 = 0x21  // kVK_ANSI_LeftBracket: the '^' dead key on a French layout
	static let quote: UInt16 = 0x27        // kVK_ANSI_Quote: 'i' and 'İ' on Turkish Q
	static let space: UInt16 = 0x31        // kVK_Space
	static let command: UInt16 = 0x37      // kVK_Command
	static let shift: UInt16 = 0x38        // kVK_Shift
	static let capsLock: UInt16 = 0x39     // kVK_CapsLock
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

/// Which string a key-down sends: VNCKeyCode.keyCodesFrom(event:).
final class MacKeyEventKeyCodesTests: XCTestCase {
	private func sent(_ event: NSEvent) -> [UInt32] {
		VNCKeyCode.keyCodesFrom(event: event).map(\.rawValue)
	}

	func testTypingSendsWhatTheKeyTypesWithCapsLockAndShiftApplied() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "A", ignoring: "a", flags: .capsLock)), [ 0x41 ],
					   "Caps Lock: the capital, where charactersIgnoringModifiers stays lower case")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "A", ignoring: "A", flags: [ .capsLock, .shift ])), [ 0x41 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "A", ignoring: "A", flags: .shift)), [ 0x41 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "a", ignoring: "a")), [ 0x61 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.minus, "_", ignoring: "_", flags: .shift)), [ 0x5f ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.two, "é", ignoring: "é")), [ 0xe9 ], "Latin-1 as itself")
	}

	func testAShortcutSendsTheKeyWithShiftAlone() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "a", ignoring: "a", flags: [ .command, .capsLock ])), [ 0x61 ],
					   "Command-A under Caps Lock is Command and a")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "\u{1}", ignoring: "a", flags: .control)), [ 0x61 ],
					   "Control-A is Control and a, not U+0001")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "\u{1}", ignoring: "A", flags: [ .control, .shift ])), [ 0x41 ])
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "å", ignoring: "a", flags: .option)), [ 0x61 ],
					   "Option-a is Alt and a, not the character Option types here")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.equal, "+", ignoring: "+", flags: [ .command, .shift ])), [ 0x2b ])
	}

	func testAnEmptyCharactersSendsTheCharacterIgnoringModifiers() {
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.e, "", ignoring: "e", flags: .option)), [ 0x65 ],
					   "Option-e, a dead key: characters is empty, as NSEvent documents")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.leftBracket, "", ignoring: "^")), [ 0x5e ],
					   "a dead key with no modifier goes as it did before")
		XCTAssertEqual(sent(keyEvent(.keyDown, Key.a, "", ignoring: "")), [ ], "a key that types nothing sends nothing")
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
}

/// What each key sent going down, by its key code: HeldKeyCodes.
final class HeldKeyCodesTests: XCTestCase {
	private let lowerA = [ VNCKeyCode(0x61) ], upperA = [ VNCKeyCode(0x41) ]

	func testAKeyComesUpAsItWentDownAndIsForgotten() {
		var held = HeldKeyCodes()

		let down = held.keyDown(Key.a, isARepeat: false) { self.upperA }

		XCTAssertEqual(down.released, [ ])
		XCTAssertEqual(down.pressed, upperA)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, upperA, "its press, not what it types now")
		XCTAssertTrue(held.isEmpty)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, lowerA, "a second key-up was never pressed: the fallback")
	}

	func testARepeatResendsThePressWithoutWorkingItOutAgain() {
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false) { self.lowerA }

		let repeated = held.keyDown(Key.a, isARepeat: true) {
			XCTFail("a repeat of a key held here is not worked out again")
			return self.upperA
		}

		XCTAssertEqual(repeated.released, [ ])
		XCTAssertEqual(repeated.pressed, lowerA)
		XCTAssertEqual(held.keyUp(Key.a) { self.upperA }, lowerA)
	}

	func testARepeatOfAKeyNeverSeenGoingDownIsAPress() {
		var held = HeldKeyCodes()

		let repeated = held.keyDown(Key.a, isARepeat: true) { self.upperA }

		XCTAssertEqual(repeated.released, [ ])
		XCTAssertEqual(repeated.pressed, upperA)
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, upperA)
	}

	func testAPressOfAKeyStillHeldLetsGoOfThatPressFirst() {
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false) { self.upperA }

		let again = held.keyDown(Key.a, isARepeat: false) { self.lowerA }

		XCTAssertEqual(again.released, upperA, "its key-up never came: the server still holds it")
		XCTAssertEqual(again.pressed, lowerA)
		XCTAssertEqual(held.keyUp(Key.a) { self.upperA }, lowerA)
		XCTAssertTrue(held.isEmpty)
	}

	func testAKeyThatSentNothingComesUpAsNothing() {
		var held = HeldKeyCodes()

		XCTAssertEqual(held.keyDown(Key.a, isARepeat: false) { [ ] }.pressed, [ ])
		XCTAssertEqual(held.keyUp(Key.a) { self.lowerA }, [ ], "not a key-up for something never pressed")
	}

	func testKeysAreRememberedApart() {
		var held = HeldKeyCodes()

		_ = held.keyDown(Key.a, isARepeat: false) { self.upperA }
		_ = held.keyDown(Key.e, isARepeat: false) { [ VNCKeyCode(0x65) ] }

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

	private func down(_ keyCode: UInt16, _ characters: String, ignoring: String,
					  flags: NSEvent.ModifierFlags = [ ], repeat isARepeat: Bool = false) {
		view.keyDown(with: keyEvent(.keyDown, keyCode, characters, ignoring: ignoring, flags: flags, repeat: isARepeat))
	}

	private func up(_ keyCode: UInt16, _ characters: String, ignoring: String, flags: NSEvent.ModifierFlags = [ ]) {
		view.keyUp(with: keyEvent(.keyUp, keyCode, characters, ignoring: ignoring, flags: flags))
	}

	private func flags(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) {
		view.flagsChanged(with: keyEvent(.flagsChanged, keyCode, "", ignoring: "", flags: flags))
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

	func testARepeatResendsThePress() {
		down(Key.minus, "-", ignoring: "-")
		flags(Key.shift, [ .shift, .leftShift ])
		down(Key.minus, "_", ignoring: "_", flags: [ .shift, .leftShift ], repeat: true)
		up(Key.minus, "_", ignoring: "_", flags: [ .shift, .leftShift ])
		flags(Key.shift, [ ])

		XCTAssertEqual(sent(), [ "down 0x2d", "down 0xffe1", "down 0x2d", "up 0x2d", "up 0xffe1" ])
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
		down(Key.e, "", ignoring: "e", flags: [ .option, .leftOption ])
		up(Key.e, "", ignoring: "e", flags: [ .option, .leftOption ])
		flags(0x3a, [ ])
		down(Key.leftBracket, "", ignoring: "^")
		up(Key.leftBracket, "", ignoring: "^")

		XCTAssertEqual(sent(), [ "down 0xffe9", "down 0x65", "up 0x65", "up 0xffe9", "down 0x5e", "up 0x5e" ])
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
