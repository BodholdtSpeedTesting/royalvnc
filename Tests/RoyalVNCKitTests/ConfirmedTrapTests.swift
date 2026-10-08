// The two traps a hostile server could spring on the kit at 2ad33e2, each found by a map of the
// parsers that read what a server sends and confirmed there by a crashing test: these tests.
//
// Both are reached before the user does anything and need no authentication at all -- with
// security type None a server is never asked to prove anything (RFC 6143 7.2.1) -- and both took
// the process down: a Swift arithmetic overflow and a range precondition are traps, not errors.
// At 2ad33e2 each test here ends the test process with a signal; since the fix each one passes.
//
// Written against nothing that 2ad33e2 lacks, so the file can be dropped into a checkout of that
// commit to watch the traps happen. The rule each fix applies is tested on its own in
// HostileServerTests.

import XCTest
@testable import RoyalVNCKit

final class ConfirmedTrapTests: XCTestCase {
	/// RFC 6143 7.7.3: an RRE rectangle is a background pixel and a count, then that many
	/// sub-rectangles, each a pixel and a U16 x-position, y-position, width and height relative
	/// to the rectangle. 2ad33e2 added the sub-rectangle's x-position to the rectangle's in
	/// UInt16: a rectangle at x 1 and a sub-rectangle at x 0xFFFF overflowed and trapped. RRE is
	/// in the decoder table whether or not the client asked for it.
	func testRRESubrectangleWhosePositionOverflowsSixteenBitsIsRefused() async throws {
		let logger = QuietLogger()
		let framebuffer = try makeTestFramebuffer(width: 100, height: 100, depth: 24, logger: logger)
		let (connection, encodings) = makeTestEncodings(logger: logger)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 1, y: 0, width: 1, height: 1, encoding: 2)
		stream.u32(1)                              // number-of-subrectangles
		stream.pixel(0x00_00_00, bytesPerPixel: 4) // background-pixel-value
		stream.pixel(0xff_ff_ff, bytesPerPixel: 4) // subrect-pixel-value
		stream.u16(0xffff)                         // x-position
		stream.u16(0)                              // y-position
		stream.u16(1)                              // width
		stream.u16(1)                              // height

		do {
			_ = try await VNCProtocol.FramebufferUpdate.receive(connection: ScriptedReader(stream.bytes),
																framebuffer: framebuffer,
																encodings: encodings,
																logger: logger)

			XCTFail("a sub-rectangle at x 0xFFFF in a rectangle at x 1 was accepted")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}

		withExtendedLifetime(connection) { }
	}

	/// RFC 6143 7.6.2: SetColourMapEntries sets the entries first-colour onwards, one per colour
	/// sent. 2ad33e2 walked `Int(firstColour)..<colours.count` -- a range whose lower bound passes
	/// its upper bound when the first colour is beyond the number of colours, which traps. Here
	/// one colour at entry 300, in a session whose pixel format uses a colour map: the kit's 8-bit
	/// depth, eight bits a pixel, so 256 entries and no entry 300 for any pixel to name.
	func testColourMapUpdateBeyondTheColoursSentIsRefused() async throws {
		let framebuffer = try makeTestFramebuffer(width: 4, height: 4, depth: 8)

		var stream = ServerStream()
		stream.setColourMapEntries(firstColour: 300, colours: [(0xffff, 0, 0)])

		let entries = try await VNCProtocol.SetColourMapEntries.receive(connection: ScriptedReader(stream.bytes),
																		logger: QuietLogger())

		XCTAssertEqual(entries.firstColour, 300)
		XCTAssertEqual(entries.colors.count, 1)

		XCTAssertThrowsError(try framebuffer.updateColorMap(entries)) { error in
			assertServerRefused(error, naming: "colourMap")
		}
	}

	/// The same message in a true-colour session -- the app's, at 24 bits -- where there is no
	/// colour map for it to set. 2ad33e2 trapped here too; the message is now read and dropped.
	func testColourMapUpdateBeyondTheColoursSentIsDroppedInATrueColourSession() async throws {
		let framebuffer = try makeTestFramebuffer(width: 4, height: 4, depth: 24)

		var stream = ServerStream()
		stream.setColourMapEntries(firstColour: 300, colours: [(0xffff, 0, 0)])

		let reader = ScriptedReader(stream.bytes)
		let entries = try await VNCProtocol.SetColourMapEntries.receive(connection: reader,
																		logger: QuietLogger())

		XCTAssertEqual(reader.remaining, 0, "the message was not read to its end")

		try framebuffer.updateColorMap(entries)
	}
}

/// That `error` is the kit refusing what a server sent -- a protocol error, which the app shows
/// and which ends the session -- and that the refusal is the one meant.
func assertServerRefused(_ error: Error,
						 naming expected: String,
						 file: StaticString = #filePath,
						 line: UInt = #line) {
	guard let vncError = error as? VNCError,
		  case .protocol(let underlying) = vncError else {
		XCTFail("expected a protocol error naming \(expected), got \(error)", file: file, line: line)

		return
	}

	XCTAssertTrue("\(underlying)".lowercased().contains(expected.lowercased()),
				  "expected a protocol error naming \(expected), got \(underlying)",
				  file: file, line: line)

	XCTAssertFalse((vncError.errorDescription ?? "").isEmpty,
				   "the error has nothing for the app to show", file: file, line: line)
}
