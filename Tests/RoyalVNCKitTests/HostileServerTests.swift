// What the kit does with server-to-client messages a server breaks the protocol with, rule by rule:
// what is refused, what is dropped, and that what a server conforming to RFC 6143 (and, for the
// encodings it leaves out, rfbproto.rst) sends decodes as it did before.
//
// Every stream here goes through the kit's own readers and decoders over a ScriptedReader, into a
// real VNCFramebuffer; a rectangle goes through VNCProtocol.FramebufferUpdate.receive and the
// decoder table a VNCConnection builds, as a live session's do. ConfirmedTrapTests holds the two
// traps that started this.

import XCTest
@testable import RoyalVNCKit

final class HostileServerTests: XCTestCase {
	// MARK: - RRE and CoRRE: sub-rectangles inside their rectangle (RFC 6143 7.7.3)

	func testRRESubrectanglesInsideTheirRectangleDecodeAsBefore() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 2, y: 3, width: 4, height: 3, encoding: 2)
		stream.u32(2)
		stream.pixel(0x11_22_33, bytesPerPixel: 4)
		stream.pixel(0xaa_bb_cc, bytesPerPixel: 4)
		stream.u16(0); stream.u16(0); stream.u16(1); stream.u16(1)
		stream.pixel(0x44_55_66, bytesPerPixel: 4)
		stream.u16(3); stream.u16(2); stream.u16(1); stream.u16(1) // the bottom-right corner

		try await session.receiveFramebufferUpdate(stream)

		XCTAssertEqual(session.pixel(2, 3), 0xaa_bb_cc)
		XCTAssertEqual(session.pixel(3, 3), 0x11_22_33)
		XCTAssertEqual(session.pixel(5, 5), 0x44_55_66)
		XCTAssertEqual(session.pixel(4, 5), 0x11_22_33)
		XCTAssertEqual(session.pixel(6, 5), 0, "drawn outside the rectangle")
		XCTAssertEqual(session.pixel(2, 6), 0, "drawn outside the rectangle")
	}

	/// Inside the framebuffer, and so drawn at 2ad33e2 -- over pixels the rectangle never claimed: one
	/// reaching past its rectangle's right edge, and one past its bottom edge.
	func testRRESubrectangleCrossingItsRectanglesEdgeIsRefused() async throws {
		let crossings: [(x: UInt16, y: UInt16, width: UInt16, height: UInt16, edge: String)] = [
			(3, 0, 2, 1, "right"),
			(0, 3, 1, 2, "bottom")
		]

		for crossing in crossings {
			let session = try TestSession(width: 32, height: 32, depth: 24)

			var stream = ServerStream()
			stream.framebufferUpdateHeader(rectangles: 1)
			stream.rectangle(x: 10, y: 10, width: 4, height: 4, encoding: 2)
			stream.u32(1)
			stream.pixel(0x11_22_33, bytesPerPixel: 4)
			stream.pixel(0xaa_bb_cc, bytesPerPixel: 4)
			stream.u16(crossing.x); stream.u16(crossing.y); stream.u16(crossing.width); stream.u16(crossing.height)

			do {
				try await session.receiveFramebufferUpdate(stream)

				XCTFail("a sub-rectangle reaching past its rectangle's \(crossing.edge) edge was drawn")
			} catch {
				assertServerRefused(error, naming: "subrectangle")
			}

			XCTAssertEqual(session.pixel(14, 10), 0, "drawn outside the rectangle")
			XCTAssertEqual(session.pixel(10, 14), 0, "drawn outside the rectangle")
		}
	}

	/// The same, a sub-rectangle starting outside its rectangle, at x 0xFFFF: 2ad33e2 trapped on
	/// the sum; see ConfirmedTrapTests. And at y.
	func testRRESubrectangleBelowItsRectangleIsRefused() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 1, width: 8, height: 8, encoding: 2)
		stream.u32(1)
		stream.pixel(0x11_22_33, bytesPerPixel: 4)
		stream.pixel(0xaa_bb_cc, bytesPerPixel: 4)
		stream.u16(0); stream.u16(0xffff); stream.u16(1); stream.u16(1)

		do {
			try await session.receiveFramebufferUpdate(stream)

			XCTFail("a sub-rectangle at y 0xFFFF was accepted")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}
	}

	/// rfbproto.rst's CoRRE: RRE with one-byte positions. A rectangle within 255 pixels of a
	/// 65535-pixel-wide framebuffer's edge took the sum past 16 bits at 2ad33e2, and trapped.
	func testCoRRESubrectanglePastSixteenBitsIsRefused() async throws {
		let session = try TestSession(width: 65535, height: 1, depth: 24)

		var stream = ServerStream()
		stream.u32(1)
		stream.pixel(0x11_22_33, bytesPerPixel: 4)
		stream.pixel(0xaa_bb_cc, bytesPerPixel: 4)
		stream.u8(255); stream.u8(0); stream.u8(1); stream.u8(1)

		let rectangle = VNCProtocol.Rectangle(xPosition: 65400, yPosition: 0, width: 135, height: 1, encodingType: 4)

		do {
			try await VNCProtocol.CoRREEncoding().decodeRectangle(rectangle,
																  framebuffer: session.framebuffer,
																  connection: ScriptedReader(stream.bytes),
																  logger: session.logger)

			XCTFail("a CoRRE sub-rectangle at x 255 in a 135-pixel rectangle was accepted")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}
	}

	func testCoRRESubrectanglesInsideTheirRectangleDecodeAsBefore() async throws {
		let session = try TestSession(width: 300, height: 4, depth: 24)

		var stream = ServerStream()
		stream.u32(1)
		stream.pixel(0x11_22_33, bytesPerPixel: 4)
		stream.pixel(0xaa_bb_cc, bytesPerPixel: 4)
		stream.u8(254); stream.u8(1); stream.u8(1); stream.u8(1)

		let rectangle = VNCProtocol.Rectangle(xPosition: 40, yPosition: 0, width: 255, height: 2, encodingType: 4)
		let reader = ScriptedReader(stream.bytes)

		try await VNCProtocol.CoRREEncoding().decodeRectangle(rectangle,
															  framebuffer: session.framebuffer,
															  connection: reader,
															  logger: session.logger)

		XCTAssertEqual(reader.remaining, 0)
		XCTAssertEqual(session.pixel(294, 1), 0xaa_bb_cc)
		XCTAssertEqual(session.pixel(293, 1), 0x11_22_33)
		XCTAssertEqual(session.pixel(295, 1), 0, "drawn outside the rectangle")
	}

	// MARK: - SetColourMapEntries: entries inside the colour map (RFC 6143 7.6.2)

	/// A server mapping the pixel values of the kit's 8-bit depth, the one format of its that uses
	/// a colour map, then a Raw rectangle of those values.
	func testColourMapColoursAnEightBitSessionsPixels() async throws {
		let session = try TestSession(width: 4, height: 1, depth: 8)

		try await session.receiveColourMapEntries(firstColour: 0, colours: [
			(0xffff, 0, 0), (0, 0xffff, 0), (0, 0, 0xffff), (0xffff, 0xffff, 0xffff)
		])

		try await session.receiveRawRectangle(width: 4, height: 1, pixels: [0, 1, 2, 3])

		XCTAssertEqual((0..<4).map { session.pixel($0, 0) }, [0xff_00_00, 0x00_ff_00, 0x00_00_ff, 0xff_ff_ff])
	}

	/// "Note that this message may only update part of the color map" (7.6.2). 2ad33e2 replaced
	/// the whole map with each message and kept only the colours from index first-colour of
	/// those sent -- so this one, one colour for entry 2, trapped there.
	func testColourMapUpdateSetsOnlyTheEntriesItNames() async throws {
		let session = try TestSession(width: 4, height: 1, depth: 8)

		try await session.receiveColourMapEntries(firstColour: 0, colours: [
			(0xffff, 0, 0), (0, 0xffff, 0), (0, 0, 0xffff), (0xffff, 0xffff, 0xffff)
		])
		try await session.receiveColourMapEntries(firstColour: 2, colours: [(0x8000, 0x8000, 0x8000)])

		try await session.receiveRawRectangle(width: 4, height: 1, pixels: [0, 1, 2, 3])

		XCTAssertEqual((0..<4).map { session.pixel($0, 0) }, [0xff_00_00, 0x00_ff_00, 0x80_80_80, 0xff_ff_ff])
	}

	/// An 8-bit pixel names 256 entries. The last can be set; one past it cannot.
	func testColourMapEntriesPastTheEightBitMapAreRefused() async throws {
		let session = try TestSession(width: 4, height: 1, depth: 8)

		try await session.receiveColourMapEntries(firstColour: 255, colours: [(0xffff, 0, 0)])
		try await session.receiveColourMapEntries(firstColour: 256, colours: [])

		do {
			try await session.receiveColourMapEntries(firstColour: 255, colours: [(0, 0xffff, 0), (0, 0, 0xffff)])

			XCTFail("colour map entries 255 and 256 were accepted for an 8-bit pixel")
		} catch {
			assertServerRefused(error, naming: "colourMap")
		}

		try await session.receiveRawRectangle(width: 1, height: 1, pixels: [255])

		XCTAssertEqual(session.pixel(0, 0), 0xff_00_00, "entry 255 lost to the refused message")
	}

	func testColourMapEntriesAreDroppedInATrueColourSession() async throws {
		let session = try TestSession(width: 4, height: 1, depth: 24)

		try await session.receiveColourMapEntries(firstColour: 0, colours: [(0xffff, 0, 0)])
		try await session.receiveColourMapEntries(firstColour: 65535, colours: [(0xffff, 0, 0), (0, 0xffff, 0)])

		XCTAssertNil(session.framebuffer.colorMap)
	}
}

// MARK: - A session's worth of decoding, without a connection

/// A framebuffer at a size and depth, the decoder table a VNCConnection builds, and a way to read
/// back what was drawn.
final class TestSession {
	let logger = QuietLogger()
	let framebuffer: VNCFramebuffer
	let encodings: Encodings

	private let connection: VNCConnection

	init(width: UInt16, height: UInt16, depth: UInt8) throws {
		framebuffer = try makeTestFramebuffer(width: width, height: height, depth: depth, logger: logger)
		(connection, encodings) = makeTestEncodings(logger: logger)
	}

	/// Hands `stream` -- a FramebufferUpdate after its message-type byte -- to the kit, and checks
	/// that the kit read all of it and no more.
	@discardableResult
	func receiveFramebufferUpdate(_ stream: ServerStream) async throws -> VNCProtocol.FramebufferUpdate {
		let reader = ScriptedReader(stream.bytes)

		let update = try await VNCProtocol.FramebufferUpdate.receive(connection: reader,
																	 framebuffer: framebuffer,
																	 encodings: encodings,
																	 logger: logger)

		XCTAssertEqual(reader.remaining, 0, "the update was not read to its end")

		return update
	}

	/// Hands the kit a SetColourMapEntries, as a session does: read, then given to the framebuffer.
	func receiveColourMapEntries(firstColour: UInt16, colours: [(UInt16, UInt16, UInt16)]) async throws {
		var stream = ServerStream()
		stream.setColourMapEntries(firstColour: firstColour, colours: colours)

		let reader = ScriptedReader(stream.bytes)
		let entries = try await VNCProtocol.SetColourMapEntries.receive(connection: reader, logger: logger)

		XCTAssertEqual(reader.remaining, 0, "the message was not read to its end")

		try framebuffer.updateColorMap(entries)
	}

	/// A Raw rectangle at the origin, its pixels one byte each (the kit's 8-bit depth).
	func receiveRawRectangle(width: UInt16, height: UInt16, pixels: [UInt8]) async throws {
		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: width, height: height, encoding: 0)
		stream.append(pixels)

		try await receiveFramebufferUpdate(stream)
	}

	/// The pixel drawn at x, y, as 0xRRGGBB.
	func pixel(_ x: Int, _ y: Int) -> UInt32 {
		let width = Int(framebuffer.size.width)
		let bytes = framebuffer.surfaceAddress.assumingMemoryBound(to: UInt8.self)
		let offset = (y * width + x) * 4

		// The kit's own layout: BGRA, eight bits a component.
		return UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
	}
}
