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
