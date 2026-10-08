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

	/// Encoding 4 through the table a connection decodes with. CoRRE's sub-rectangles are four
	/// bytes after their pixel, RRE's eight; read as RRE, as they were at 2ad33e2, two CoRRE
	/// sub-rectangles became one RRE sub-rectangle and the rest of the stream was read out of step.
	func testCoRRERectangleIsReadWithOneBytePositions() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 2)
		stream.rectangle(x: 4, y: 4, width: 8, height: 8, encoding: 4)
		stream.u32(2)
		stream.pixel(0x11_22_33, bytesPerPixel: 4)
		stream.pixel(0xaa_bb_cc, bytesPerPixel: 4)
		stream.u8(1); stream.u8(2); stream.u8(3); stream.u8(1)
		stream.pixel(0x44_55_66, bytesPerPixel: 4)
		stream.u8(7); stream.u8(7); stream.u8(1); stream.u8(1)
		// And a rectangle after it, which a reader out of step would not find.
		stream.rectangle(x: 0, y: 0, width: 1, height: 1, encoding: 0)
		stream.pixel(0x77_88_99, bytesPerPixel: 4)

		try await session.receiveFramebufferUpdate(stream)

		XCTAssertEqual(session.pixel(5, 6), 0xaa_bb_cc)
		XCTAssertEqual(session.pixel(7, 6), 0xaa_bb_cc)
		XCTAssertEqual(session.pixel(8, 6), 0x11_22_33)
		XCTAssertEqual(session.pixel(11, 11), 0x44_55_66)
		XCTAssertEqual(session.pixel(0, 0), 0x77_88_99)
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

	// MARK: - Hextile and ZRLE: tiles and subrectangles in Int, inside their tile (7.7.4, 7.7.6)

	/// Four tiles -- 16x16, a narrower last column, a shorter last row -- each a different way:
	/// background, foreground and one subrectangle; raw; coloured subrectangles; nothing, its
	/// background carried over.
	func testHextileTilesDecodeAsBefore() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 1, y: 1, width: 20, height: 18, encoding: 5)

		stream.u8(2 | 4 | 8) // BackgroundSpecified, ForegroundSpecified, AnySubrects
		stream.pixel(0x10_10_10, bytesPerPixel: 4)
		stream.pixel(0xf0_f0_f0, bytesPerPixel: 4)
		stream.u8(1)
		stream.u8(2 << 4 | 3); stream.u8(1 << 4 | 0) // at 2,3; 2x1

		stream.u8(1) // Raw: 4x16
		for index in 0..<64 {
			stream.pixel(UInt32(index), bytesPerPixel: 4)
		}

		stream.u8(2 | 8 | 16) // BackgroundSpecified, AnySubrects, SubrectsColoured: 16x2
		stream.pixel(0x20_20_20, bytesPerPixel: 4)
		stream.u8(2)
		stream.pixel(0xaa_00_00, bytesPerPixel: 4); stream.u8(0 << 4 | 0); stream.u8(0 << 4 | 1) // at 0,0; 1x2
		stream.pixel(0x00_aa_00, bytesPerPixel: 4); stream.u8(15 << 4 | 1); stream.u8(0 << 4 | 0) // at 15,1; 1x1

		stream.u8(0) // nothing: the last background, 4x2

		try await session.receiveFramebufferUpdate(stream)

		XCTAssertEqual(session.pixel(1, 1), 0x10_10_10)
		XCTAssertEqual(session.pixel(3, 4), 0xf0_f0_f0)
		XCTAssertEqual(session.pixel(4, 4), 0xf0_f0_f0)
		XCTAssertEqual(session.pixel(5, 4), 0x10_10_10)
		XCTAssertEqual(session.pixel(17, 1), 0)
		XCTAssertEqual(session.pixel(20, 16), 63)
		XCTAssertEqual(session.pixel(1, 17), 0xaa_00_00)
		XCTAssertEqual(session.pixel(1, 18), 0xaa_00_00)
		XCTAssertEqual(session.pixel(2, 17), 0x20_20_20)
		XCTAssertEqual(session.pixel(16, 18), 0x00_aa_00)
		XCTAssertEqual(session.pixel(20, 18), 0x20_20_20)
		XCTAssertEqual(session.pixel(21, 18), 0, "drawn outside the rectangle")
		XCTAssertEqual(session.pixel(1, 19), 0, "drawn outside the rectangle")
	}

	/// The last tile of a 20-pixel-wide rectangle is 4 wide; a subrectangle 2 wide at x 3 reaches
	/// past it, into pixels the rectangle does not have. At 2ad33e2 it was drawn there.
	func testHextileSubrectanglePastANarrowerLastTileIsRefused() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: 20, height: 16, encoding: 5)
		stream.u8(2) // a solid first tile
		stream.pixel(0x10_10_10, bytesPerPixel: 4)
		stream.u8(4 | 8) // the 4x16 last tile: the background carried over, a foreground, a subrectangle
		stream.pixel(0xf0_f0_f0, bytesPerPixel: 4)
		stream.u8(1)
		stream.u8(3 << 4 | 0); stream.u8(1 << 4 | 0) // at 3,0; 2x1

		do {
			try await session.receiveFramebufferUpdate(stream)

			XCTFail("a subrectangle reaching past its tile was drawn")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}

		XCTAssertEqual(session.pixel(20, 0), 0, "drawn outside the rectangle")
	}

	/// The last row of tiles of a 20-pixel-high rectangle is 4 high; a subrectangle 2 high at y 3
	/// reaches past it, into pixels the rectangle does not have. At 2ad33e2 it was drawn there.
	func testHextileSubrectanglePastAShorterLastRowIsRefused() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: 16, height: 20, encoding: 5)
		stream.u8(2) // a solid first tile
		stream.pixel(0x10_10_10, bytesPerPixel: 4)
		stream.u8(4 | 8) // the 16x4 tile below it: the background carried over, a foreground, a subrectangle
		stream.pixel(0xf0_f0_f0, bytesPerPixel: 4)
		stream.u8(1)
		stream.u8(0 << 4 | 3); stream.u8(0 << 4 | 1) // at 0,3; 1x2

		do {
			try await session.receiveFramebufferUpdate(stream)

			XCTFail("a subrectangle reaching past its tile was drawn")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}

		XCTAssertEqual(session.pixel(0, 20), 0, "drawn outside the rectangle")
	}

	/// A full tile is 16 wide; a subrectangle 2 wide at x 15 reaches past it, into the next tile.
	func testHextileSubrectanglePastSixteenIsRefused() async throws {
		let session = try TestSession(width: 32, height: 32, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: 32, height: 16, encoding: 5)
		stream.u8(2 | 4 | 8)
		stream.pixel(0x10_10_10, bytesPerPixel: 4)
		stream.pixel(0xf0_f0_f0, bytesPerPixel: 4)
		stream.u8(1)
		stream.u8(15 << 4 | 15); stream.u8(1 << 4 | 0) // at 15,15; 2x1

		do {
			try await session.receiveFramebufferUpdate(stream)

			XCTFail("a subrectangle reaching past 16 was drawn")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}
	}

	/// A rectangle ending at a 65535-pixel-wide framebuffer's right edge, its last tile 3 wide:
	/// a subrectangle inside it is drawn at x 65534, and one at x 15, past it, is refused -- at
	/// 2ad33e2 the tile's x plus 15 passed 65535 in UInt16, and trapped.
	func testHextileAtTheEdgeOfA65535PixelWideFramebuffer() async throws {
		let session = try TestSession(width: 65535, height: 16, depth: 24)

		func update(subrectX: UInt8) -> ServerStream {
			var stream = ServerStream()
			stream.framebufferUpdateHeader(rectangles: 1)
			stream.rectangle(x: 65500, y: 0, width: 35, height: 1, encoding: 5)
			stream.u8(2)
			stream.pixel(0x10_10_10, bytesPerPixel: 4)
			stream.u8(0)
			stream.u8(4 | 8)
			stream.pixel(0xf0_f0_f0, bytesPerPixel: 4)
			stream.u8(1)
			stream.u8(subrectX << 4); stream.u8(0)

			return stream
		}

		try await session.receiveFramebufferUpdate(update(subrectX: 2))

		XCTAssertEqual(session.pixel(65534, 0), 0xf0_f0_f0)
		XCTAssertEqual(session.pixel(65533, 0), 0x10_10_10)

		do {
			try await session.receiveFramebufferUpdate(update(subrectX: 15))

			XCTFail("a subrectangle at x 15 of a 3-pixel-wide tile was accepted")
		} catch {
			assertServerRefused(error, naming: "subrectangle")
		}
	}

	/// A rectangle as wide as a 65535-pixel-wide framebuffer: 4,096 tiles, the last 15 wide, the
	/// first a background and the rest carrying it over. At 2ad33e2 the number of tiles, worked
	/// out as the width plus 15 in UInt16, passed 65535 before a tile was read, and trapped.
	func testHextileRectangleAs65535PixelsWideAsItsFramebufferDecodes() async throws {
		let session = try TestSession(width: 65535, height: 1, depth: 24)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: 65535, height: 1, encoding: 5)
		stream.u8(2)
		stream.pixel(0x10_20_30, bytesPerPixel: 4)
		stream.append([UInt8](repeating: 0, count: 4095))

		try await session.receiveFramebufferUpdate(stream)

		XCTAssertEqual(session.pixel(0, 0), 0x10_20_30)
		XCTAssertEqual(session.pixel(65519, 0), 0x10_20_30)
		XCTAssertEqual(session.pixel(65534, 0), 0x10_20_30)
	}

	/// A ZRLE rectangle whose one tile ends at a 65535-pixel-wide framebuffer's right edge. At
	/// 2ad33e2 the next tile's x, 65472 plus 64, passed 65535 in UInt16, and trapped.
	func testZRLEAtTheEdgeOfA65535PixelWideFramebuffer() async throws {
		let session = try TestSession(width: 65535, height: 1, depth: 24)

		var zlib = ZlibStoredStream()
		let tiles = zlib.chunk([1, 0xcc, 0xbb, 0xaa]) // solid; a CPIXEL, least significant byte first

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 65472, y: 0, width: 63, height: 1, encoding: 16)
		stream.u32(UInt32(tiles.count))
		stream.append(tiles)

		try await session.receiveFramebufferUpdate(stream)

		XCTAssertEqual(session.pixel(65472, 0), 0xaa_bb_cc)
		XCTAssertEqual(session.pixel(65534, 0), 0xaa_bb_cc)
		XCTAssertEqual(session.pixel(65471, 0), 0, "drawn outside the rectangle")
	}

	// MARK: - ZRLE: a packed palette index inside its palette (7.7.5)

	/// "each pixel represented as a bit field yielding a zero-based index into the palette": a
	/// palette of three takes a 2-bit field, which can also say 3. Copying entry 3 of three read
	/// past the palette, and trapped -- in a 24-bit session with ZRLE, the app's own.
	func testZRLEPackedPaletteIndexPastItsPaletteIsRefused() async throws {
		let session = try TestSession(width: 8, height: 1, depth: 24)

		do {
			try await session.receiveZRLE(width: 4, height: 1, tiles: [
				3, 0x11, 0x11, 0x11, 0x22, 0x22, 0x22, 0x33, 0x33, 0x33, 0b00_01_10_11
			])

			XCTFail("palette index 3 of a palette of three was accepted")
		} catch {
			assertServerRefused(error, naming: "palette")
		}
	}

	func testZRLEPackedPaletteTileDecodesAsBefore() async throws {
		let session = try TestSession(width: 8, height: 1, depth: 24)

		try await session.receiveZRLE(width: 4, height: 1, tiles: [
			3, 0x11, 0x11, 0x11, 0x22, 0x22, 0x22, 0x33, 0x33, 0x33, 0b00_01_10_10
		])

		XCTAssertEqual((0..<5).map { session.pixel($0, 0) }, [0x11_11_11, 0x22_22_22, 0x33_33_33, 0x33_33_33, 0])
	}

	// MARK: - Length checks a release build keeps

	/// ZRLE's tiles are read from what the server's zlib data inflated to, a length the server
	/// chooses. Here a raw 4x1 tile with 3 bytes of its 12: a debug build refused it, a release
	/// build asked Data for bytes past its end and trapped. Run in both (`swift test` and
	/// `swift test -c release`).
	func testZRLETileDataEndingEarlyIsRefused() async throws {
		let session = try TestSession(width: 8, height: 1, depth: 24)

		do {
			try await session.receiveZRLE(width: 4, height: 1, tiles: [0, 0x11, 0x22, 0x33])

			XCTFail("a raw tile of 3 bytes for 4 pixels was accepted")
		} catch {
			assertServerRefused(error, naming: "noData")
		}
	}

	/// No decoder hands `fill` a pixel of another length -- each reads one PIXEL -- so this is the
	/// kit's own mistake, and the fill is dropped, as a debug build always dropped it. A release
	/// build read the pixel's first three bytes, or a 16-bit load, past its end.
	func testFillWithAPixelOfTheWrongLengthDrawsNothing() throws {
		for (depth, pixel) in [(UInt8(24), Data([1, 2])), (24, Data([1, 2, 3, 4, 5])), (16, Data([1])), (8, Data())] {
			let logger = QuietLogger()
			let framebuffer = try makeTestFramebuffer(width: 4, height: 4, depth: depth, logger: logger)
			var pixel = pixel

			framebuffer.fill(region: .init(x: 0, y: 0, width: 2, height: 2), withPixel: &pixel)

			let bytes = framebuffer.surfaceAddress.assumingMemoryBound(to: UInt8.self)

			XCTAssertTrue((0..<64).allSatisfy { bytes[$0] == 0 }, "a \(pixel.count)-byte pixel was drawn at depth \(depth)")
			XCTAssertEqual(logger.errorCount, 1)
		}
	}

	/// A pixel that is a slice of a larger Data -- its first byte at index 1 -- filled in a 24-bit
	/// session, whose fill copies the pixel's bytes without converting them. The kit read them as
	/// pixelData[0], [1] and [2], and index 0 is not the slice's: it trapped. No decoder hands
	/// fill such a slice today (ZRLE's are slices from 0), so this was a trap waiting for one.
	func testFillWithAPixelThatIsASliceDrawsIt() throws {
		let framebuffer = try makeTestFramebuffer(width: 4, height: 4, depth: 24)
		let backing = Data([0xee, 0x33, 0x22, 0x11, 0x00, 0xee])
		var pixel = backing[1..<5]

		XCTAssertEqual(pixel.startIndex, 1)

		framebuffer.fill(region: .init(x: 1, y: 1, width: 1, height: 1), withPixel: &pixel)

		let bytes = framebuffer.surfaceAddress.assumingMemoryBound(to: UInt8.self)
		let offset = (1 * 4 + 1) * 4

		XCTAssertEqual([bytes[offset], bytes[offset + 1], bytes[offset + 2]], [0x33, 0x22, 0x11])
	}

	/// The same for `update`, whose rows are copied out of the data with no check of their own.
	func testUpdateWithFewerBytesThanItsRegionDrawsNothing() throws {
		let logger = QuietLogger()
		let framebuffer = try makeTestFramebuffer(width: 4, height: 4, depth: 24, logger: logger)

		var short = Data(repeating: 0xff, count: 15)
		framebuffer.update(region: .init(x: 0, y: 0, width: 2, height: 2), data: &short)

		let bytes = framebuffer.surfaceAddress.assumingMemoryBound(to: UInt8.self)

		XCTAssertTrue((0..<64).allSatisfy { bytes[$0] == 0 }, "15 bytes were drawn as a 2x2 region")
		XCTAssertEqual(logger.errorCount, 1)

		var enough = Data(repeating: 0xff, count: 16)
		framebuffer.update(region: .init(x: 0, y: 0, width: 2, height: 2), data: &enough)

		XCTAssertEqual(bytes[0], 0xff)
		XCTAssertEqual(bytes[4 * 4 + 4 + 2], 0xff)
		XCTAssertEqual(logger.errorCount, 1)
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

	/// A ZRLE rectangle at the origin whose zlib data inflates to `tiles`, on the session's one
	/// ZRLE stream.
	func receiveZRLE(width: UInt16, height: UInt16, tiles: [UInt8]) async throws {
		let chunk = zrleStream.chunk(tiles)

		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: width, height: height, encoding: 16)
		stream.u32(UInt32(chunk.count))
		stream.append(chunk)

		try await receiveFramebufferUpdate(stream)
	}

	private var zrleStream = ZlibStoredStream()

	/// The pixel drawn at x, y, as 0xRRGGBB.
	func pixel(_ x: Int, _ y: Int) -> UInt32 {
		let width = Int(framebuffer.size.width)
		let bytes = framebuffer.surfaceAddress.assumingMemoryBound(to: UInt8.self)
		let offset = (y * width + x) * 4

		// The kit's own layout: BGRA, eight bits a component.
		return UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
	}
}
