// What the fuzzing of server-to-client messages found -- the seeded fuzz in ServerToClientFuzzTests
// and the libFuzzer runs in Tools/fuzz -- and what the review of that work found past it, each the
// smallest stream that shows it, kept as a test.

import XCTest
@testable import RoyalVNCKit

final class FuzzFindingTests: XCTestCase {
	// MARK: - Tight's JPEG (rfbproto.rst, Tight Encoding)

	/// A JPEG that cannot be read. Away from Apple's platforms swift-jpeg decodes it, and its own
	/// error -- a LexingError -- reached the embedder as it was, where every other decoder's is a
	/// VNCError with something to show. Found by the seeded fuzz on Linux: with this fix taken out,
	/// 227 of the 32,000 sessions at seeds 11 to 18 (19 of the 3,000 at its defaults) end with it.
	func testTightJPEGThatCannotBeReadIsRefusedWithTheKitsError() async throws {
		for jpeg: [UInt8] in [
			[0xff, 0xd8, 0xff, 0xc0, 0x00, 0x03, 0x01],
			[0xff, 0xd8, 0x00, 0x01, 0x02, 0x03, 0xff, 0xd9],
			[0xff, 0xd8, 0xff, 0xda, 0x00, 0x02, 0xff, 0xd9],
			[0x00]
		] {
			let session = try TestSession(width: 16, height: 16, depth: 24)

			var stream = ServerStream()
			stream.framebufferUpdateHeader(rectangles: 1)
			stream.rectangle(x: 0, y: 0, width: 8, height: 8, encoding: 7)
			stream.u8(0x90) // JpegCompression
			stream.u8(UInt8(jpeg.count)) // a compact length of one byte
			stream.append(jpeg)

			do {
				try await session.receiveFramebufferUpdate(stream)

				XCTFail("\(jpeg) was drawn as a JPEG")
			} catch {
				XCTAssertTrue(error is VNCError, "\(jpeg): \(type(of: error)) \(error)")
			}
		}
	}

	// MARK: - Tight's JPEG is the rectangle's size (rfbproto.rst, Tight Encoding; ITU-T T.81)

	/// A baseline JPEG (ITU-T T.81) whose frame header (B.2.2) declares `width` x `height`: a
	/// quantization table of ones, a DC and an AC Huffman table of one one-bit code each (DC
	/// difference category 0, AC end of block), one scan of every component whose entropy-coded
	/// data is `scan` -- `blocks(_:)`, or zero bytes, four mid-grey blocks each -- then a DNL
	/// segment (B.2.5) of `lines` if given, and the end of the image.
	static func jpeg(width: UInt16,
					 height: UInt16,
					 components: Int = 1,
					 scan: [UInt8],
					 lines: UInt16? = nil) -> [UInt8] {
		var bytes: [UInt8] = [0xff, 0xd8]

		bytes += [0xff, 0xdb, 0x00, 0x43, 0x00] + [UInt8](repeating: 1, count: 64)
		bytes += [0xff, 0xc0, 0x00, UInt8(8 + 3 * components), 0x08,
				  UInt8(height >> 8), UInt8(height & 0xff), UInt8(width >> 8), UInt8(width & 0xff),
				  UInt8(components)]

		for component in 1...components {
			bytes += [UInt8(component), 0x11, 0x00]
		}

		bytes += [0xff, 0xc4, 0x00, 0x14, 0x00, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00]
		bytes += [0xff, 0xc4, 0x00, 0x14, 0x10, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00]
		bytes += [0xff, 0xda, 0x00, UInt8(6 + 2 * components), UInt8(components)]

		for component in 1...components {
			bytes += [UInt8(component), 0x00]
		}

		bytes += [0x00, 0x3f, 0x00]
		bytes += scan

		if let lines {
			bytes += [0xff, 0xdc, 0x00, 0x04, UInt8(lines >> 8), UInt8(lines & 0xff)]
		}

		bytes += [0xff, 0xd9]

		return bytes
	}

	/// Entropy-coded data of `count` mid-grey blocks, `bitsEach` zero bits a block -- two in a
	/// sequential scan of `jpeg(...)`'s tables, one in a progressive DC scan -- its final byte
	/// padded with 1-bits, as T.81 B.1.1.5 has an encoder pad it.
	static func blocks(_ count: Int, bitsEach: Int = 2) -> [UInt8] {
		let bits = count * bitsEach
		var bytes = [UInt8](repeating: 0, count: (bits + 7) / 8)

		if bits % 8 != 0 {
			bytes[bytes.count - 1] = 0xff >> (bits % 8)
		}

		return bytes
	}

	/// A FramebufferUpdate of one Tight rectangle at the origin carrying `jpeg` (rfbproto.rst,
	/// lines 3505-3533: JpegCompression, a compact length, then the JPEG).
	static func tightJPEGUpdate(width: UInt16, height: UInt16, jpeg: [UInt8]) -> ServerStream {
		var stream = ServerStream()
		stream.framebufferUpdateHeader(rectangles: 1)
		stream.rectangle(x: 0, y: 0, width: width, height: height, encoding: 7)
		stream.u8(0x90)

		// Seven bits a byte, the third byte's eight the most significant.
		var length = [UInt8(jpeg.count & 0x7f)]

		if jpeg.count > 0x7f {
			length[0] |= 0x80
			length.append(UInt8((jpeg.count >> 7) & 0x7f))

			if jpeg.count > 0x3fff {
				length[1] |= 0x80
				length.append(UInt8((jpeg.count >> 14) & 0xff))
			}
		}

		stream.append(length)
		stream.append(jpeg)

		return stream
	}

	/// Whether the kit refused `stream` with `invalidData`, as the checks of a JPEG's frame
	/// against its rectangle do, rather than drawing it or failing to decode it; a test failure
	/// naming `label` where it did not.
	private func isRefusedAsInvalidData(_ stream: ServerStream,
										framebufferWidth: UInt16,
										framebufferHeight: UInt16,
										label: String,
										file: StaticString = #filePath,
										line: UInt = #line) async throws -> Bool {
		let session = try TestSession(width: framebufferWidth, height: framebufferHeight, depth: 24)

		do {
			try await session.receiveFramebufferUpdate(stream)
		} catch {
			let refused = "\(error)".contains("invalidData")

			XCTAssertTrue(refused, "\(label): \(error)", file: file, line: line)

			if refused {
				assertServerRefused(error, naming: "invalidData", file: file, line: line)
			}

			return refused
		}

		XCTFail("\(label): drawn", file: file, line: line)

		return false
	}

	/// JPEGs whose frame header is not their 16 x 8 rectangle's size, each scan a byte, four
	/// blocks. Refused before anything is made at the frame's size; were that check gone, a frame
	/// wider or taller than the rectangle would be decoded, run out of entropy-coded data, and fail
	/// with swift-jpeg's error, wrapped as frameDecode, and a height of zero -- one a DNL would
	/// define (T.81 B.2.2) -- would trap in swift-jpeg's inverse DCT. ImageIO, on Apple's
	/// platforms, reports the frame's size, which the kit refuses likewise.
	func testTightJPEGWhoseFrameIsNotItsRectanglesIsRefused() async throws {
		for (frameWidth, frameHeight) in [(UInt16(64), UInt16(64)), (64, 8), (16, 64), (8, 8), (16, 0)] {
			let stream = Self.tightJPEGUpdate(width: 16, height: 8,
											  jpeg: Self.jpeg(width: frameWidth, height: frameHeight, scan: [0]))

			_ = try await isRefusedAsInvalidData(stream, framebufferWidth: 32, framebufferHeight: 32,
												 label: "a \(frameWidth) x \(frameHeight) frame in a 16 x 8 rectangle")
		}
	}

	/// The review's message, whole: a one-pixel Tight rectangle whose 156-byte JPEG declares a
	/// frame of 65535 x 65535, its scan sixteen bytes. swift-jpeg's one-call decompress made the
	/// image at the frame's size before the kit compared it with the rectangle: a Linux viewer
	/// was killed for its memory (8.5 GB extrapolated; 551 MB at 16384 x 16384). Sent only once
	/// smaller frames are seen refused before decoding, so that should that check go, this test
	/// fails rather than taking the memory of whoever runs it.
	func testTheReviewsTightJPEGDeclaring65535By65535IsRefused() async throws {
		let canary = Self.tightJPEGUpdate(width: 16, height: 8, jpeg: Self.jpeg(width: 64, height: 64, scan: [0]))

		guard try await isRefusedAsInvalidData(canary, framebufferWidth: 32, framebufferHeight: 32,
											   label: "a 64 x 64 frame in a 16 x 8 rectangle") else {
			return
		}

		let message = hexBytes("00000001000000000001000100000007909c01ffd8ffdb004300"
							   + String(repeating: "01", count: 64)
							   + "ffc0000b08ffffffff01011100"
							   + "ffc40014000100000000000000000000000000000000"
							   + "ffc40014100100000000000000000000000000000000"
							   + "ffda0008010100003f00"
							   + String(repeating: "00", count: 16)
							   + "ffd9")

		XCTAssertEqual(message.count, 175)
		XCTAssertEqual(message.first, 0, "a FramebufferUpdate")

		var stream = ServerStream()
		stream.append(Array(message.dropFirst()))

		_ = try await isRefusedAsInvalidData(stream, framebufferWidth: 64, framebufferHeight: 64,
											 label: "the review's message")
	}

	/// The frame header's height is the rectangle's, but a DNL segment after the first scan
	/// (T.81 B.2.5) redefines it -- the way past a check of the frame header alone. Any DNL is
	/// refused: here one restating the height (decoded and drawn were it not refused), then the
	/// review's, a 16384 x 1 frame in a 16384 x 1 rectangle redefined to 65,535 lines, which took
	/// a Linux viewer past 4 GiB with only the frame header checked; sent only once the first is
	/// seen refused.
	func testTightJPEGWithADNLSegmentIsRefused() async throws {
		try skipWhereImageIODecodesJPEGs()

		let canary = Self.tightJPEGUpdate(width: 16, height: 8,
										  jpeg: Self.jpeg(width: 16, height: 8, scan: Self.blocks(2), lines: 8))

		guard try await isRefusedAsInvalidData(canary, framebufferWidth: 32, framebufferHeight: 32,
											   label: "a DNL restating the height") else {
			return
		}

		let review = Self.tightJPEGUpdate(width: 16384, height: 1,
										  jpeg: Self.jpeg(width: 16384, height: 1, scan: Self.blocks(2048), lines: 65535))

		_ = try await isRefusedAsInvalidData(review, framebufferWidth: 16384, framebufferHeight: 1,
											 label: "the review's DNL of 65,535 lines")
	}

	/// A scan holding more lines than its frame header declares: swift-jpeg's one-call decompress
	/// decoded a first scan's data past the frame's last line (its `extend`), growing the image's
	/// planes for as long as there was data -- two megabytes of it in a 2048 x 8 rectangle, in the
	/// review, took them past a gigabyte -- and kept only the frame's lines. The kit decodes the
	/// frame's lines and leaves the rest unread. First a 24 x 8 frame, three blocks, whose scan
	/// holds four: drawn, where decoding the fourth as the start of another row of blocks would
	/// fail with the data ending mid-row; then, only once that is seen, a 16 x 8 frame whose scan
	/// holds 4,096 lines, and the review's.
	func testTightJPEGScanHoldingMoreLinesThanItsFrameDrawsTheFrame() async throws {
		try skipWhereImageIODecodesJPEGs()

		for (width, scan) in [(UInt16(24), [UInt8](repeating: 0, count: 1)),
							  (16, [UInt8](repeating: 0, count: 256)),
							  (2048, [UInt8](repeating: 0, count: 2_000_000))] {
			let session = try TestSession(width: width, height: 8, depth: 24)

			try await session.receiveFramebufferUpdate(Self.tightJPEGUpdate(width: width, height: 8,
																			jpeg: Self.jpeg(width: width, height: 8, scan: scan)))

			XCTAssertEqual(session.pixel(0, 0), 0x808080)
			XCTAssertEqual(session.pixel(Int(width) - 1, 7), 0x808080)
		}
	}

	/// A scan whose data ends before its frame's last block. swift-jpeg's one-call decompress
	/// stopped a first scan quietly where its data ran out at the end of a row of blocks, and drew
	/// the rows it had no data for mid-grey. Decoding the frame's lines and no more, the kit asks
	/// for every one of them, and swift-jpeg's truncatedEntropyCodedSegment ends the session as
	/// frameDecode, as data ending inside a row of blocks always did: a 16 x 16 frame whose scan
	/// holds one row of its two, and one whose scan holds no data. ImageIO, on Apple's platforms,
	/// draws both.
	func testTightJPEGScanEndingBeforeItsFramesLastBlockIsRefused() async throws {
		try skipWhereImageIODecodesJPEGs()

		for (label, scan) in [("one row of blocks of two", Self.blocks(2)), ("no data", [UInt8]())] {
			let session = try TestSession(width: 32, height: 32, depth: 24)
			let update = Self.tightJPEGUpdate(width: 16, height: 16, jpeg: Self.jpeg(width: 16, height: 16, scan: scan))

			do {
				try await session.receiveFramebufferUpdate(update)

				XCTFail("a 16 x 16 frame whose scan holds \(label): drawn")
			} catch {
				assertServerRefused(error, naming: "frameDecode")
				XCTAssertTrue("\(error)".contains("truncatedEntropyCodedSegment"), "\(label): \(error)")
			}
		}
	}

	/// JPEGs of their rectangle's size, their entropy-coded data padded as T.81 has it, decode as
	/// before: one and three components, sizes that are and are not whole blocks, a progressive
	/// one (G.1.1.1.1, a DC scan alone), and restart intervals (B.2.4.4) -- their RSTm markers in
	/// order, and refused out of order, as swift-jpeg refused them.
	func testTightJPEGOfItsRectanglesSizeIsDrawn() async throws {
		try skipWhereImageIODecodesJPEGs()

		for (side, components) in [(8, 1), (16, 3), (12, 1), (20, 3)] {
			let blocks = ((side + 7) / 8) * ((side + 7) / 8) * components

			await assertDrawnMidGrey(width: UInt16(side), height: UInt16(side),
									 jpeg: Self.jpeg(width: UInt16(side), height: UInt16(side),
													 components: components, scan: Self.blocks(blocks)),
									 label: "\(side) x \(side), \(components) component(s)")
		}

		// Progressive (SOF2), one DC scan (Ss 0, Se 0, Ah 0, Al 0): a bit a block.
		var progressive = Self.jpeg(width: 16, height: 16, scan: Self.blocks(4, bitsEach: 1))
		let frame = progressive.firstIndex(of: 0xc0)!
		progressive[frame] = 0xc2

		let scanParameters = progressive.count - 2 - 1 - 3
		progressive.replaceSubrange(scanParameters..<scanParameters + 3, with: [0x00, 0x00, 0x00])

		await assertDrawnMidGrey(width: 16, height: 16, jpeg: progressive, label: "progressive")

		// A restart interval (DRI) of one row of MCUs in a 16 x 16 frame -- swift-jpeg decodes an
		// interval as whole rows -- so two intervals of two one-block MCUs, each interval's four
		// bits padded with ones to a byte, RST0 between them; then RST1 there instead.
		for restart: UInt8 in [0xd0, 0xd1] {
			var jpeg = Self.jpeg(width: 16, height: 16, scan: [])
			let scan = jpeg.count - 2 - 10

			jpeg.insert(contentsOf: [0xff, 0xdd, 0x00, 0x04, 0x00, 0x02], at: scan)
			jpeg.insert(contentsOf: [0x0f, 0xff, restart, 0x0f], at: jpeg.count - 2)

			if restart == 0xd0 {
				await assertDrawnMidGrey(width: 16, height: 16, jpeg: jpeg, label: "restart intervals")
			} else {
				let session = try TestSession(width: 32, height: 32, depth: 24)

				do {
					try await session.receiveFramebufferUpdate(Self.tightJPEGUpdate(width: 16, height: 16, jpeg: jpeg))

					XCTFail("RST1 where RST0 belongs: drawn")
				} catch {
					XCTAssertTrue(error is VNCError, "RST1 where RST0 belongs: \(error)")
				}
			}
		}
	}

	/// A test failure naming `label` unless `jpeg`, in a Tight rectangle of its size at the
	/// origin, is drawn mid-grey to its far corner.
	private func assertDrawnMidGrey(width: UInt16,
									height: UInt16,
									jpeg: [UInt8],
									label: String,
									file: StaticString = #filePath,
									line: UInt = #line) async {
		do {
			let session = try TestSession(width: width, height: height, depth: 24)

			try await session.receiveFramebufferUpdate(Self.tightJPEGUpdate(width: width, height: height, jpeg: jpeg))

			XCTAssertEqual(session.pixel(0, 0), 0x808080, label, file: file, line: line)
			XCTAssertEqual(session.pixel(Int(width) - 1, Int(height) - 1), 0x808080, label, file: file, line: line)
		} catch {
			XCTFail("\(label): \(error)", file: file, line: line)
		}
	}

	/// The JPEG tests that exercise swift-jpeg's staged decoding: ImageIO decodes Tight's JPEGs on
	/// Apple's platforms, and has its own rules for a DNL or a long scan.
	private func skipWhereImageIODecodesJPEGs() throws {
#if canImport(ImageIO) && canImport(CoreGraphics)
		throw XCTSkip("ImageIO decodes Tight's JPEGs here; swift-jpeg away from Apple's platforms")
#endif
	}

	// MARK: - ServerCutText (RFC 6143 7.6.4; rfbproto.rst's extended form)

	private func receiveCutText(_ stream: ServerStream) async throws -> (VNCProtocol.ServerCutText, remaining: Int) {
		let reader = ScriptedReader(stream.bytes)
		let cutText = try await VNCProtocol.ServerCutText.receive(connection: reader, logger: QuietLogger())

		return (cutText, reader.remaining)
	}

	/// A length of 0x80000000 is Int32.min read as signed, which the kit takes for the extended
	/// form, and `Int32(abs(length))` -- one past Int32.max -- trapped. Found by the seeded fuzz:
	/// with this fix taken out, its default run traps at seed 1, session 20 (counting from 0).
	func testServerCutTextOfLength0x80000000IsRefused() async throws {
		var stream = ServerStream()
		stream.append([0, 0, 0])
		stream.u32(0x8000_0000)
		stream.append(Array("hello".utf8))

		do {
			_ = try await receiveCutText(stream)

			XCTFail("a ServerCutText of length 0x80000000 was accepted")
		} catch {
			assertServerRefused(error, naming: "invalidData")
		}
	}

	func testServerCutTextDecodesAsBefore() async throws {
		var stream = ServerStream()
		stream.append([0, 0, 0])
		stream.u32(5)
		stream.append(Array("hello".utf8))
		stream.u8(2) // a Bell after it

		let (cutText, remaining) = try await receiveCutText(stream)

		XCTAssertEqual(cutText.text, "hello")
		XCTAssertNil(cutText.extended)
		XCTAssertEqual(remaining, 1)
	}

	/// A caps message (format bits 0 and 15, so two sizes, of which the kit reads bit 0's) and a
	/// provide message with data the kit does not read, each followed by a Bell: the stream stays
	/// in step, where the bytes the kit did not read used to be read as the next message.
	func testExtendedServerCutTextIsReadToItsEnd() async throws {
		var caps = ServerStream()
		caps.u32(1 << 24 | 1 << 15 | 1)
		caps.u32(1024); caps.u32(1024)

		// The kit compares a non-caps message's flags whole, format bits and all, so a provide is
		// one with no format bit set.
		var provide = ServerStream()
		provide.u32(1 << 28)
		provide.append([0x78, 0x01, 0x01, 0x00, 0x00, 0xff, 0xff])

		for body in [caps, provide] {
			var stream = ServerStream()
			stream.append([0, 0, 0])
			stream.s32(-Int32(body.bytes.count))
			stream.append(body.bytes)
			stream.u8(2)

			let (cutText, remaining) = try await receiveCutText(stream)

			XCTAssertNotNil(cutText.extended)
			XCTAssertEqual(remaining, 1, "the message was not read to its end, and no further")
		}
	}

	/// Shorter than its own flags, or caps whose sizes run past the message: refused, where they
	/// were read into whatever came next.
	func testExtendedServerCutTextShorterThanItsContentIsRefused() async throws {
		var tooShort = ServerStream()
		tooShort.append([0, 0, 0])
		tooShort.s32(-2)
		tooShort.append([0, 0, 2])

		var sizesPastTheEnd = ServerStream()
		sizesPastTheEnd.append([0, 0, 0])
		sizesPastTheEnd.s32(-8)
		sizesPastTheEnd.u32(1 << 24 | 0b111) // three formats, three sizes: 12 bytes, in a message of 4
		sizesPastTheEnd.u32(1024)
		sizesPastTheEnd.u8(2)

		for stream in [tooShort, sizesPastTheEnd] {
			do {
				_ = try await receiveCutText(stream)

				XCTFail("an extended ServerCutText shorter than its content was accepted")
			} catch {
				assertServerRefused(error, naming: "invalidData")
			}
		}
	}
}
