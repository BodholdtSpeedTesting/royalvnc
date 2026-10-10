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

	/// Images that are not JPEGs, sent as a Tight rectangle's JpegCompression, whose data is a
	/// JPEG (rfbproto.rst, lines 3505-3533: "The *jpeg-data* is a JFIF stream"): one 8 x 8 image as
	/// ImageIO writes it as a PNG, a TIFF and a GIF. On Apple's platforms ImageIO picked its decoder
	/// by what the bytes look like and drew each of them -- and OpenEXR, HEIC, PSD, TGA and more --
	/// where swift-jpeg, elsewhere, reads nothing but JPEGs. None is drawn now, on any platform:
	/// where ImageIO decodes, bytes that do not begin with SOI and another marker (ITU-T T.81
	/// B.1.1.2, B.2.1) are refused as invalidData before ImageIO sees them, and so is anything
	/// ImageIO does not take for a JPEG; elsewhere swift-jpeg's error ends the session as
	/// frameDecode, as before. A JPEG of the same size is still drawn, on every platform. Found in
	/// review round 3.
	///
	/// On every input tried, each of the two checks refuses whatever the other does, so this pins
	/// the two together: with either one alone it still passes.
	func testTightRectangleWhoseJPEGIsAnotherFormatIsNotDrawn() async throws {
		let png = hexBytes("""
			89504e47 0d0a1a0a 0000000d 49484452 00000008 00000008 08020000 004b6d29
			dc000000 01735247 4200aece 1ce90000 00386558 49664d4d 002a0000 00080001
			87690004 00000001 0000001a 00000000 0002a002 00040000 00010000 0008a003
			00040000 00010000 00080000 0000b64c 59680000 00184944 4154081d 63fcffbf
			e1010303 26620189 61038353 0200cc8b 0edca373 fdd60000 00004945 4e44ae42
			6082
			""")

		let tiff = hexBytes("""
			4d4d002a 000000c8 ffff80df ff80bfff 809fff80 7fff805f ff803fff 801fff80
			ffdf80df df80bfdf 809fdf80 7fdf805f df803fdf 801fdf80 ffbf80df bf80bfbf
			809fbf80 7fbf805f bf803fbf 801fbf80 ff9f80df 9f80bf9f 809f9f80 7f9f805f
			9f803f9f 801f9f80 ff7f80df 7f80bf7f 809f7f80 7f7f805f 7f803f7f 801f7f80
			ff5f80df 5f80bf5f 809f5f80 7f5f805f 5f803f5f 801f5f80 ff3f80df 3f80bf3f
			809f3f80 7f3f805f 3f803f3f 801f3f80 ff1f80df 1f80bf1f 809f1f80 7f1f805f
			1f803f1f 801f1f80 000e0100 00030000 00010008 00000101 00030000 00010008
			00000102 00030000 00030000 01760103 00030000 00010001 00000106 00030000
			00010002 0000010a 00030000 00010001 00000111 00040000 00010000 00080112
			00030000 00010001 00000115 00030000 00010003 00000116 00030000 00010008
			00000117 00040000 00010000 00c0011c 00030000 00010001 00000128 00030000
			00010002 00000153 00030000 00030000 017c0000 00000008 00080008 00010001
			0001
			""")

		let gif = hexBytes("""
			47494638 37610800 0800e600 00000000 1f1f803f 1f805f1f 807f1f80 9f1f80bf
			1f80df1f 80ff1f80 1f3f803f 3f805f3f 807f3f80 9f3f80bf 3f80df3f 80ff3f80
			1f5f803f 5f805f5f 807f5f80 9f5f80bf 5f80df5f 80ff5f80 1f7f803f 7f805f7f
			807f7f80 9f7f80bf 7f80df7f 80ff7f80 1f9f803f 9f805f9f 807f9f80 9f9f80bf
			9f80df9f 80ff9f80 1fbf803f bf805fbf 807fbf80 9fbf80bf bf80dfbf 80ffbf80
			1fdf803f df805fdf 807fdf80 9fdf80bf df80dfdf 80ffdf80 1fff803f ff805fff
			807fff80 9fff80bf ff80dfff 80ffff80 ffffff00 00000000 00000000 00000000
			00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
			00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
			00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
			00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
			00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
			00000000 00000000 00000000 0021f904 04000000 002c0000 00000800 08000007
			4280403f 3e3d3c3b 3a393837 36353433 3231302f 2e2d2c2b 2a292827 26252423
			2221201f 1e1d1c1b 1a191817 16151413 1211100f 0e0d0c0b 0a090807 06050403
			02018100 3b
			""")

		XCTAssertEqual([png.count, tiff.count, gif.count], [162, 386, 485])

		for (format, image) in [("PNG", png), ("TIFF", tiff), ("GIF", gif)] {
			let session = try TestSession(width: 8, height: 8, depth: 24)

			do {
				try await session.receiveFramebufferUpdate(Self.tightJPEGUpdate(width: 8, height: 8, jpeg: image))

				XCTFail("a \(format) sent as a Tight JPEG was drawn")
			} catch {
#if canImport(ImageIO) && canImport(CoreGraphics)
				assertServerRefused(error, naming: "invalidData")
#else
				assertServerRefused(error, naming: "frameDecode")
#endif
			}
		}

		await assertDrawnMidGrey(width: 8, height: 8, jpeg: Self.jpeg(width: 8, height: 8, scan: Self.blocks(1)),
								 label: "an 8 x 8 JPEG")
	}

	// MARK: - Tight's JPEG is the rectangle's size (rfbproto.rst, Tight Encoding; ITU-T T.81)

	/// A baseline JPEG (ITU-T T.81) whose frame header (B.2.2) declares `width` x `height`, each
	/// component sampled `sampling` (H and V, four bits each): a quantization table of ones, a DC
	/// and an AC Huffman table of one one-bit code each (DC difference category 0, AC end of
	/// block), one scan of every component whose entropy-coded data is `scan` -- `blocks(_:)`, or
	/// zero bytes, four mid-grey blocks each -- then a DNL segment (B.2.5) of `lines` if given, and
	/// the end of the image.
	static func jpeg(width: UInt16,
					 height: UInt16,
					 components: Int = 1,
					 sampling: UInt8 = 0x11,
					 scan: [UInt8],
					 lines: UInt16? = nil) -> [UInt8] {
		var bytes: [UInt8] = [0xff, 0xd8]

		bytes += [0xff, 0xdb, 0x00, 0x43, 0x00] + [UInt8](repeating: 1, count: 64)
		bytes += [0xff, 0xc0, 0x00, UInt8(8 + 3 * components), 0x08,
				  UInt8(height >> 8), UInt8(height & 0xff), UInt8(width >> 8), UInt8(width & 0xff),
				  UInt8(components)]

		for component in 1...components {
			bytes += [UInt8(component), sampling, 0x00]
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

	/// A marker segment (ITU-T T.81 B.1.1.4): X'FF' and the marker's code, then a two-byte length
	/// that counts itself and `payload`.
	static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
		[0xff, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xff)] + payload
	}

	/// A DRI segment (T.81 B.2.4.4): a restart interval of `interval` MCUs.
	static func restartInterval(_ interval: UInt16) -> [UInt8] {
		segment(0xdd, [UInt8(interval >> 8), UInt8(interval & 0xff)])
	}

	/// A scan header (T.81 B.2.3): `components`, each with DC and AC table 0, then Ss, Se, Ah and Al.
	static func scanHeader(_ components: [UInt8], ss: UInt8, se: UInt8, ah: UInt8 = 0, al: UInt8 = 0) -> [UInt8] {
		segment(0xda, [UInt8(components.count)] + components.flatMap { [$0, 0x00] } + [ss, se, ah << 4 | al])
	}

	/// A scan's entropy-coded data in `count` restart-delimited segments (T.81 B.2.1), each
	/// `segment`, an RSTm marker between each two, m counting 0 to 7 from the scan's first.
	static func restartSegments(_ segment: [UInt8], count: Int) -> [UInt8] {
		var bytes = [UInt8]()

		for k in 0..<count {
			if k > 0 { bytes += [0xff, 0xd0 | UInt8((k - 1) % 8)] }

			bytes += segment
		}

		return bytes
	}

	/// A progressive JPEG (T.81 SOF2; B.2.2) of a `side` x `side` image of three components, the
	/// first sampled `firstSampling` and the other two 1 x 1, with `jpeg(...)`'s quantization and
	/// Huffman tables; then `scans`, the scans and whatever comes between them, and the end of the
	/// image. Every coefficient the scans carry is zero -- each block a DC difference of category
	/// 0 or a refinement bit of 0, its AC bands an end of block -- so the image is mid-grey.
	static func progressiveJPEG(side: UInt16, firstSampling: UInt8, scans: [UInt8]) -> [UInt8] {
		var bytes: [UInt8] = [0xff, 0xd8]

		bytes += segment(0xdb, [0x00] + [UInt8](repeating: 1, count: 64))
		bytes += segment(0xc2, [0x08, UInt8(side >> 8), UInt8(side & 0xff), UInt8(side >> 8), UInt8(side & 0xff), 0x03,
								0x01, firstSampling, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00])
		bytes += segment(0xc4, [0x00, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00])
		bytes += segment(0xc4, [0x10, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00])

		return bytes + scans + [0xff, 0xd9]
	}

	/// A progressive JPEG (ITU-T T.81, SOF2) of an 8 x 8 one-component image: a DC first scan and
	/// an AC first scan (band 1-63), each entropy-coded segment one 0x7f byte, a restart interval
	/// (DRI, B.2.4.4) of one data unit, and `acSegments` restart-delimited segments in the AC scan
	/// with RSTm markers between them. The 8 x 8 image is a single data unit, so two or more AC
	/// segments place a segment at or past the grid. The DRI follows the Huffman tables or, with
	/// `driBeforeFrame`, directly follows SOI: a frame header may be preceded by table-specification
	/// and miscellaneous segments (B.2.1), a DRI among them (B.2.4).
	static func progressiveRestartJPEG(acSegments: Int, driBeforeFrame: Bool = false) -> [UInt8] {
		var bytes: [UInt8] = [0xff, 0xd8]

		if driBeforeFrame {
			bytes += restartInterval(1)
		}

		bytes += segment(0xdb, [0x00] + [UInt8](repeating: 1, count: 64))
		bytes += segment(0xc2, [0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00])
		bytes += segment(0xc4, [0x00, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00])
		bytes += segment(0xc4, [0x10, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00])

		if !driBeforeFrame {
			bytes += restartInterval(1)
		}

		bytes += scanHeader([1], ss: 0, se: 0) + [0x7f]
		bytes += scanHeader([1], ss: 1, se: 63) + restartSegments([0x7f], count: acSegments)

		return bytes + [0xff, 0xd9]
	}

	/// Restart-delimited segments (T.81 B.2.4.4) past the grid of the scan under test, refused
	/// before the scan is decoded. `jpeg(n)` is a `side` x `side` JPEG in which that scan has n
	/// segments, at a restart interval of one unit over a grid of one: one segment, conformant, is
	/// drawn mid-grey; two, three and four are refused as invalidData. swift-jpeg's decoders of a
	/// progressive scan's AC bands and of DC refinement clamp only the upper bound of a segment's
	/// row range, so a segment that starts past the grid traps them ("Range requires lowerBound <=
	/// upperBound"), but the second segment's range is empty: were the guard to miss them, two
	/// segments would be drawn, not trapped on. They are the canary. Three and four, which do trap,
	/// are sent only once two are seen refused, so that a guard gone wrong fails the test rather
	/// than crashing whoever runs it.
	private func assertSegmentsPastTheGridAreRefused(side: UInt16,
													 label: String,
													 jpeg: (Int) -> [UInt8],
													 file: StaticString = #filePath,
													 line: UInt = #line) async throws {
		await assertDrawnMidGrey(width: side, height: side, jpeg: jpeg(1), label: "\(label), one segment",
								 file: file, line: line)

		guard try await isRefusedAsInvalidData(Self.tightJPEGUpdate(width: side, height: side, jpeg: jpeg(2)),
											   framebufferWidth: 32, framebufferHeight: 32,
											   label: "\(label), two segments", file: file, line: line) else {
			return
		}

		for segments in [3, 4] {
			_ = try await isRefusedAsInvalidData(Self.tightJPEGUpdate(width: side, height: side, jpeg: jpeg(segments)),
												 framebufferWidth: 32, framebufferHeight: 32,
												 label: "\(label), \(segments) segments", file: file, line: line)
		}
	}

	/// A progressive JPEG whose AC scan is split by restart markers into more restart-delimited
	/// segments than its grid of data units holds. swift-jpeg's progressive AC and refining band
	/// decoders clamp only the upper bound of a segment's row range (`blocks.lowerBound / units.x
	/// ..< min(blocks.upperBound / units.x, units.y)`), so a segment beginning at or past the grid
	/// gives a Range with lowerBound > upperBound and traps (signal 5), through the staged decoder
	/// and through the one-call decompress alike -- a pre-existing swift-jpeg defect the frame-header
	/// gating did not cover. The kit now bounds the segments against the grid and refuses the excess
	/// before the scan is decoded. Found in review round 2. (ImageIO, on Apple's platforms, decodes
	/// the image.)
	///
	/// An 8 x 8 one-component image is a single data unit, so two or more AC segments are excess;
	/// two are the canary (`assertSegmentsPastTheGridAreRefused`). With the DRI after the frame
	/// header and with it before: the guard takes the restart interval in force from either, and a
	/// guard that lost one defined before the frame missed every segment here (review round 3).
	func testTightJPEGProgressiveScanWithExcessRestartSegmentsIsRefused() async throws {
		try skipWhereImageIODecodesJPEGs()

		for driBeforeFrame in [false, true] {
			try await assertSegmentsPastTheGridAreRefused(side: 8,
														  label: "a progressive AC scan, its DRI \(driBeforeFrame ? "before" : "after") the frame header") {
				Self.progressiveRestartJPEG(acSegments: $0, driBeforeFrame: driBeforeFrame)
			}
		}
	}

	/// The guard measures an interleaved scan (more than one component; T.81 A.2.3) against the
	/// frame's MCU grid. Two progressive frames, each a single MCU, with an interleaved DC
	/// refinement scan (Ah 1, Al 0, after a DC first scan at Al 1; G.1.1.1.2) split into restart
	/// segments at an interval of one MCU: an 8 x 8 frame of three components sampled 1 x 1, and a
	/// 16 x 16 one whose first component is sampled 2 x 2, its data units 2 x 2. Left unbounded, an
	/// interleaved scan's three segments trap swift-jpeg's interleaved refinement decoder; measured
	/// by its first component's data units, the second frame's three would get through to it
	/// (review round 3). (ImageIO, on Apple's platforms, decodes these.)
	func testTightJPEGInterleavedScanWithExcessRestartSegmentsIsRefused() async throws {
		try skipWhereImageIODecodesJPEGs()

		// One bit a block: three blocks to the MCU, then six.
		for (side, firstSampling, mcu) in [(UInt16(8), UInt8(0x11), UInt8(0x1f)), (16, 0x22, 0x03)] {
			try await assertSegmentsPastTheGridAreRefused(side: side,
														  label: "an interleaved DC refinement scan, \(side) x \(side)") {
				Self.progressiveJPEG(side: side,
									 firstSampling: firstSampling,
									 scans: Self.restartInterval(1)
										+ Self.scanHeader([1, 2, 3], ss: 0, se: 0, al: 1) + [mcu]
										+ Self.scanHeader([1, 2, 3], ss: 0, se: 0, ah: 1)
										+ Self.restartSegments([mcu], count: $0))
			}
		}
	}

	/// The guard measures a scan of one component (T.81 A.2.2) against that component's own data
	/// units, whichever component it is. A 16 x 16 progressive frame whose first component, sampled
	/// 2 x 2, has 2 x 2 data units and whose second has one, and an AC first scan (G.1.1.1.1) of the
	/// second split into restart segments at an interval of one unit. Measured by the frame's first
	/// component, three segments would get through, and swift-jpeg's AC decoder traps on them
	/// (review round 3). (ImageIO, on Apple's platforms, decodes this.)
	func testTightJPEGScanOfALaterComponentWithExcessRestartSegmentsIsRefused() async throws {
		try skipWhereImageIODecodesJPEGs()

		try await assertSegmentsPastTheGridAreRefused(side: 16, label: "an AC scan of the second component") {
			Self.progressiveJPEG(side: 16,
								 firstSampling: 0x22,
								 scans: Self.scanHeader([1, 2, 3], ss: 0, se: 0) + [0x03]
									+ Self.restartInterval(1)
									+ Self.scanHeader([2], ss: 1, se: 63)
									+ Self.restartSegments([0x7f], count: $0))
		}
	}

	/// The restart-segment guard's legal edge. Every entropy-coded segment of a scan but the last
	/// holds the restart interval's Ri MCUs, and "The last one shall contain whatever number of MCUs
	/// completes the scan" (T.81 B.2.1): fewer than Ri, or a single one. The guard refuses only a
	/// segment that begins at or past the end of the scan's grid, so each of these conformant JPEGs,
	/// its intervals whole rows as swift-jpeg decodes them, is drawn: (a) one component, 16 x 24, its
	/// 2 x 3 data units in intervals of two rows, the last of them one row; (b) the same frame as one
	/// interleaved scan of three components sampled 1 x 1 (A.2.3), its 2 x 3 MCUs so divided; (c) one
	/// component, 8 x 16, one data unit wide, in intervals of one unit, the last beginning at its last
	/// unit; and (d) (a)'s grid in a progressive frame, a DC first scan and then an AC first scan
	/// (G.1.1.1.1) so divided. A guard rewritten to refuse a partial last interval (segments x
	/// interval <= units) refuses (a), (b) and (d), and one a unit tighter (the last segment's first
	/// unit before the grid's last, so never a last interval of one MCU) refuses (c); each passed
	/// every other test (review round 4). (ImageIO, on Apple's platforms, draws all four too; the
	/// guard is on the swift-jpeg path alone.)
	func testTightJPEGWhoseLastRestartIntervalIsPartialOrOneUnitIsDrawn() async throws {
		try skipWhereImageIODecodesJPEGs()

		// (a) Six blocks, two bits a block in a sequential scan: a DRI of four (two rows), then four
		// blocks, RST0, and two.
		var oneComponent = Self.jpeg(width: 16, height: 24, scan: [])

		oneComponent.insert(contentsOf: Self.restartInterval(4), at: oneComponent.count - 2 - 10)
		oneComponent.insert(contentsOf: Self.blocks(4) + [0xff, 0xd0] + Self.blocks(2), at: oneComponent.count - 2)

		await assertDrawnMidGrey(width: 16, height: 24, jpeg: oneComponent,
								 label: "one component, 16 x 24, its last restart interval one row of two")

		// (b) Six MCUs of three blocks: four MCUs, RST0, and two.
		var interleaved = Self.jpeg(width: 16, height: 24, components: 3, scan: [])

		interleaved.insert(contentsOf: Self.restartInterval(4), at: interleaved.count - 2 - 14)
		interleaved.insert(contentsOf: Self.blocks(12) + [0xff, 0xd0] + Self.blocks(6), at: interleaved.count - 2)

		await assertDrawnMidGrey(width: 16, height: 24, jpeg: interleaved,
								 label: "an interleaved scan, 16 x 24, its last restart interval one row of two")

		// (c) Two blocks in a column: a DRI of one, then a block, RST0, and a block.
		var oneWide = Self.jpeg(width: 8, height: 16, scan: [])

		oneWide.insert(contentsOf: Self.restartInterval(1), at: oneWide.count - 2 - 10)
		oneWide.insert(contentsOf: Self.restartSegments(Self.blocks(1), count: 2), at: oneWide.count - 2)

		await assertDrawnMidGrey(width: 8, height: 16, jpeg: oneWide,
								 label: "one component, 8 x 16, one data unit wide, a restart interval of one unit")

		// (d) Progressive (SOF2), one component, 16 x 24: a DC first scan, a bit a block; then a DRI of
		// four and an AC first scan (band 1-63), an end of block a block: four blocks, RST0, and two.
		var progressive: [UInt8] = [0xff, 0xd8]

		progressive += Self.segment(0xdb, [0x00] + [UInt8](repeating: 1, count: 64))
		progressive += Self.segment(0xc2, [0x08, 0x00, 0x18, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00])
		progressive += Self.segment(0xc4, [0x00, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00])
		progressive += Self.segment(0xc4, [0x10, 0x01] + [UInt8](repeating: 0, count: 15) + [0x00])
		progressive += Self.scanHeader([1], ss: 0, se: 0) + Self.blocks(6, bitsEach: 1)
		progressive += Self.restartInterval(4)
		progressive += Self.scanHeader([1], ss: 1, se: 63)
			+ Self.blocks(4, bitsEach: 1) + [0xff, 0xd0] + Self.blocks(2, bitsEach: 1)
		progressive += [0xff, 0xd9]

		await assertDrawnMidGrey(width: 16, height: 24, jpeg: progressive,
								 label: "a progressive AC scan, 16 x 24, its last restart interval one row of two")
	}

	/// A DNL segment (T.81 B.2.5) of zero lines. a8d3f92 refuses every DNL before swift-jpeg parses
	/// it, which keeps this from reaching swift-jpeg's DNL parser: that parser traps on a DNL of
	/// zero lines (HeightRedefinition's "height must be positive"; T.81 Table B.10 gives NL as 1 to
	/// 65,535), through the one-call decompress, at df80ea1 and at main's pin. a8d3f92 removed the
	/// trap without recording it; review round 2 pins it. No canary is needed -- the DNL refusal is
	/// in place already. (ImageIO, on Apple's platforms, draws this JPEG.)
	func testTightJPEGWithADNLOfZeroLinesIsRefused() async throws {
		try skipWhereImageIODecodesJPEGs()

		let update = Self.tightJPEGUpdate(width: 16, height: 8,
										  jpeg: Self.jpeg(width: 16, height: 8, scan: Self.blocks(2), lines: 0))

		_ = try await isRefusedAsInvalidData(update, framebufferWidth: 32, framebufferHeight: 32,
											 label: "a DNL of zero lines")
	}

	/// An application segment after SOI -- here an APP0 whose identifier is "JFIX", not "JFIF".
	/// swift-jpeg's one-call decompress read the first APP0 and APP1 directly after SOI as JFIF and
	/// EXIF and refused a malformed one; the staged decoder passes over every application and comment
	/// segment unread, wherever it is, as ImageIO does, and draws the image. Noted in review round 2.
	func testTightJPEGWithAnApplicationSegmentAfterSOIIsDrawn() async throws {
		try skipWhereImageIODecodesJPEGs()

		var jpeg = Self.jpeg(width: 8, height: 8, scan: Self.blocks(1))

		jpeg.insert(contentsOf: [0xff, 0xe0, 0x00, 0x07, 0x4a, 0x46, 0x49, 0x58, 0x00], at: 2)

		await assertDrawnMidGrey(width: 8, height: 8, jpeg: jpeg, label: "an APP0 'JFIX' after SOI")
	}

	/// JPEGs of their rectangle's size, their entropy-coded data padded as T.81 has it, decode as
	/// before: one and three components, sizes that are and are not whole blocks, a progressive
	/// one (G.1.1.1.1, a DC scan alone), and restart intervals (B.2.4.4) -- their RSTm markers in
	/// order, and refused out of order, as swift-jpeg refused them; and as many restart intervals as
	/// a scan's own grid holds, where that is not the frame's MCU grid or the MCU grid is not one
	/// data unit: an interleaved scan, and scans of a component sampled 2 x 2.
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

		// Each scan's restart intervals counted against its own grid, which the restart-segment
		// guard has to measure (review round 3). An interleaved scan's is the MCU grid (A.2.3): 16 x
		// 16, three components sampled 1 x 1, so 2 x 2 MCUs of three blocks; a DRI of two MCUs, a
		// row, each interval's twelve bits padded to two bytes.
		var interleaved = Self.jpeg(width: 16, height: 16, components: 3, scan: [])

		interleaved.insert(contentsOf: Self.restartInterval(2), at: interleaved.count - 2 - 14)
		interleaved.insert(contentsOf: Self.restartSegments([0x00, 0x0f], count: 2), at: interleaved.count - 2)

		await assertDrawnMidGrey(width: 16, height: 16, jpeg: interleaved,
								 label: "restart intervals in an interleaved scan")

		// A scan of one component, its own data units (A.2.2): 16 x 16 sampled 2 x 2, so 2 x 2 units
		// where the frame's MCU grid is one MCU; a DRI of two units, a row, four bits an interval.
		var subsampled = Self.jpeg(width: 16, height: 16, sampling: 0x22, scan: [])

		subsampled.insert(contentsOf: Self.restartInterval(2), at: subsampled.count - 2 - 10)
		subsampled.insert(contentsOf: Self.restartSegments([0x0f], count: 2), at: subsampled.count - 2)

		await assertDrawnMidGrey(width: 16, height: 16, jpeg: subsampled,
								 label: "restart intervals in a scan of a component sampled 2 x 2")

		// The same in a progressive frame of three components, the first sampled 2 x 2, so one MCU
		// of six blocks: an interleaved DC first scan, then an AC first scan (G.1.1.1.1) of the first
		// component alone, a row of its units -- two blocks, an end of block each -- an interval.
		let progressiveRestarts = Self.progressiveJPEG(side: 16,
													   firstSampling: 0x22,
													   scans: Self.restartInterval(2)
														+ Self.scanHeader([1, 2, 3], ss: 0, se: 0) + [0x03]
														+ Self.scanHeader([1], ss: 1, se: 63)
														+ Self.restartSegments([0x3f], count: 2))

		await assertDrawnMidGrey(width: 16, height: 16, jpeg: progressiveRestarts,
								 label: "restart intervals in a progressive scan of a component sampled 2 x 2")
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
