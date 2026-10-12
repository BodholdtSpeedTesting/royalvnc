// What the kit asks of its transport for a frame: reads of up to a block, served to the decoders a
// field at a time, and never one read of the transport per field.
//
// Every field a decoder reads is a read of the connection -- a Hextile tile's subencoding mask, its
// colours, its subrectangle count, then each subrectangle's two bytes (RFC 6143 7.7.4) -- and before
// this each one was a read of the transport too: one NWConnection receive, and one continuation, per
// field. A desktop's wallpaper makes a first frame of 100k-460k subrectangles, and a Mac viewer took
// 14.8-21.3 seconds over GNOME's 2.8 MB first frame, where the same frame took 0.54 s through the
// fork's socket transport, which already served many reads from one recv. Each frame here goes
// through a whole VNCConnection, handshake and all, over a ScriptedTransport that counts its reads.

import Foundation
import XCTest
@testable import RoyalVNCKit

final class BlockReadTests: XCTestCase {
	/// The two colours of the noise below, as 0xRRGGBB.
	private static let dark: UInt32 = 0x20_30_40
	private static let light: UInt32 = 0xc0_d0_e0

	/// A 1280x800 frame of two-colour noise as one Hextile rectangle -- 4,000 tiles, each its
	/// background, its foreground and every run of foreground pixels in a row a subrectangle, about
	/// 60 a tile -- is read from the transport in blocks: as many reads as the script's size over a
	/// block of 64 KiB, and one more at its end. At d360fe0 it was read one field at a time, about
	/// half a million reads. The pixels drawn are the frame's, every one.
	func testALargeHextileFrameIsReadInBlocksAndDrawnAsSent() async throws {
		let width = 1280
		let height = 800
		let image = Self.noise(width: width, height: height)

		var messages = ServerStream()
		messages.u8(0) // FramebufferUpdate
		messages.framebufferUpdateHeader(rectangles: 1)
		messages.rectangle(x: 0, y: 0, width: UInt16(width), height: UInt16(height), encoding: 5)

		let subrectangles = Self.hextile(image, width: width, height: height, into: &messages)

		let script = ScriptedServer.serverInit(width: UInt16(width), height: UInt16(height)) + messages.bytes
		let transport = ScriptedTransport(script: script)
		let drawn = await Self.draw(over: transport, width: UInt16(width), height: UInt16(height))

		XCTAssertTrue(drawn.ending.contains("closed"), "the session ended otherwise: \(drawn.ending)")
		XCTAssertEqual(drawn.width, width)
		XCTAssertEqual(drawn.height, height)

		// Counted rather than compared whole: a million-pixel array in a failure message says nothing.
		let differing = (0..<min(drawn.pixels.count, image.count)).filter { drawn.pixels[$0] != image[$0] }

		XCTAssertEqual(drawn.pixels.count, image.count)
		XCTAssertEqual(differing.count, 0,
					   "\(differing.count) pixels differ, the first at \(differing.first.map { "(\($0 % width), \($0 / width))" } ?? "-")")

		// The kit's block: `ReceivedBytes.chunkSize`. Written out rather than read from there, so this
		// test runs -- and fails -- against a kit that has no such block.
		let block = 64 * 1024
		let reads = transport.readCount

		XCTAssertLessThanOrEqual(reads, script.count / block + 2, """
			\(reads) reads of the transport for a script of \(script.count) bytes holding \
			\(subrectangles) subrectangles: it should be read in blocks of up to \(block) bytes
			""")
	}

	/// What a TLS upgrade's transport is handed is the connection as it stands, the bytes the kit has
	/// already read from it but not used among them. VeNCrypt (rfbproto.rst, "VeNCrypt", lines
	/// 661-790) settles on a TLS subtype -- here X509None, 260 -- and after the server's one-byte
	/// acknowledgement "the TLS handshake is performed" (line 763): the bytes after that acknowledgement
	/// are the TLS layer's to read. A kit that reads ahead has them already, and must hand them on in
	/// front of everything else; here the embedder's provider reads them from the transport it is
	/// given. (A server sends nothing between the acknowledgement and the client's first TLS message,
	/// so in practice there is nothing to hand on; this is the case where there is.)
	func testBytesReadAheadOfATLSUpgradeReachTheTransportItIsHandedOn() async throws {
		let handshake = Array("the first bytes after the acknowledgement".utf8)

		var stream = ServerStream()
		stream.append(Array("RFB 003.008\n".utf8))
		stream.u8(1)        // number-of-security-types
		stream.u8(19)       // VeNCrypt
		stream.u8(0)        // its version: 0.2 (lines 670-675)
		stream.u8(2)
		stream.u8(0)        // the version ack: zero means success (lines 688-690)
		stream.u8(1)        // one subtype (lines 700-705)
		stream.u32(260)     // X509None (line 716)
		stream.u8(1)        // the subtype ack: one means success (lines 741-743)
		stream.append(handshake)

		let transport = ScriptedTransport(script: stream.bytes)
		let handedOn = HandedOn()
		let watcher = ConnectionOutcome()

		let connection = VNCConnection(settings: Self.settings(colorDepth: .depth24Bit),
									   logger: QuietLogger(),
									   framebufferAllocator: CappedAllocator(limit: 64 * 1024 * 1024),
									   context: nil)

		connection.transportProvider = { _, _ in transport }
		connection.tlsUpgradeProvider = { upgrading, _ in
			let read = try await upgrading.readTransport(minimumLength: handshake.count,
														 maximumLength: handshake.count)

			handedOn.record(read)

			// Nothing to upgrade to: the bytes are what this test is about.
			throw HandedOn.Stop()
		}
		connection.delegate = watcher
		connection.connect()

		let outcome = await watcher.outcome(within: 10)

		connection.disconnect()

		guard case .disconnected = outcome else {
			return XCTFail("the connection was not ended by the provider: \(outcome)")
		}

		XCTAssertEqual(handedOn.bytes, Data(handshake),
					   "the TLS layer's transport began with \(handedOn.bytes.map { "\($0.count) other bytes" } ?? "nothing it could read")")
	}

	/// A connection given no transport -- the Apple app's direct connections, and viewer-probe --
	/// dials one of its own (`TransportNetworkConnection(settings:)`): an NWConnection on Apple
	/// platforms, the socket connection elsewhere. That is the path the slow first frame was
	/// measured on, and its reads are served in blocks as a supplied transport's are. The other
	/// tests here hand theirs over through `transportProvider`, so a dialled transport put in place
	/// unbuffered, as at d360fe0, passed them all. Nothing is started, so nothing is dialled.
	func testADialledConnectionIsReadThroughTheBuffer() {
		let connection = VNCConnection(settings: Self.settings(colorDepth: .depth24Bit),
									   logger: QuietLogger(),
									   framebufferAllocator: CappedAllocator(limit: 1024 * 1024),
									   context: nil)

		let transport = connection.connection.transport

		guard let buffered = transport as? BufferedTransport else {
			return XCTFail("the dialled transport is \(type(of: transport)), not behind the buffer")
		}

#if canImport(Network)
		XCTAssertTrue(buffered.base is NWConnectionTransport, "the buffer holds \(type(of: buffered.base))")
#else
		XCTAssertTrue(buffered.base is SocketConnectionTransport, "the buffer holds \(type(of: buffered.base))")
#endif
	}

	/// The transport a TLS upgrade puts in place is read in blocks too. VeNCrypt X509None, as above;
	/// the provider hands back a transport carrying the rest of the stream: the SecurityResult,
	/// ServerInit (RFC 6143 7.1.3, 7.3.2) and a 320x256 checkerboard as one Hextile rectangle, its
	/// 320 tiles each a background, a foreground and 128 one-pixel subrectangles (7.7.4). A
	/// `replaceTransport` that put the upgrade in place unbuffered read it a field at a time --
	/// 83,225 reads, measured at 1d50ace's review -- and every other test passed.
	func testATransportPutInPlaceByATLSUpgradeIsReadInBlocks() async throws {
		let width = 320
		let height = 256
		let image = (0..<width * height).map { index in
			(index % width + index / width) % 2 == 0 ? Self.dark : Self.light
		}

		var plain = ServerStream()
		plain.append(Array("RFB 003.008\n".utf8))
		plain.u8(1)         // number-of-security-types
		plain.u8(19)        // VeNCrypt
		plain.u8(0)         // its version: 0.2
		plain.u8(2)
		plain.u8(0)         // the version ack: success
		plain.u8(1)         // one subtype
		plain.u32(260)      // X509None
		plain.u8(1)         // the subtype ack: success

		// What the TLS layer would carry: the rest of `ScriptedServer.serverInit`'s stream.
		var messages = ServerStream()
		messages.u32(0)     // SecurityResult: OK
		messages.u16(UInt16(width))
		messages.u16(UInt16(height))
		messages.append([32, 24, 0, 1]) // bits-per-pixel, depth, big-endian, true-colour
		messages.u16(255); messages.u16(255); messages.u16(255)
		messages.append([16, 8, 0, 0, 0, 0]) // shifts, padding
		messages.u32(4)
		messages.append(Array("test".utf8))
		messages.u8(0) // FramebufferUpdate
		messages.framebufferUpdateHeader(rectangles: 1)
		messages.rectangle(x: 0, y: 0, width: UInt16(width), height: UInt16(height), encoding: 5)

		let subrectangles = Self.hextile(image, width: width, height: height, into: &messages)

		let plainTransport = ScriptedTransport(script: plain.bytes)
		let upgraded = ScriptedTransport(script: messages.bytes)
		let watcher = DrawingWatcher()

		let connection = VNCConnection(settings: Self.settings(colorDepth: .depth24Bit),
									   logger: QuietLogger(),
									   framebufferAllocator: CappedAllocator(limit: 64 * 1024 * 1024),
									   context: nil)

		connection.transportProvider = { _, _ in plainTransport }
		connection.tlsUpgradeProvider = { _, _ in upgraded }
		connection.delegate = watcher
		connection.connect()

		let deadline = Date().addingTimeInterval(120)

		while Date() < deadline, !watcher.result.ended {
			try? await Task.sleep(nanoseconds: 20_000_000)
		}

		connection.disconnect()

		let drawn = watcher.result.drawn
		let differing = (0..<min(drawn.pixels.count, image.count)).filter { drawn.pixels[$0] != image[$0] }

		XCTAssertTrue(drawn.ending.contains("closed"), "the session ended otherwise: \(drawn.ending)")
		XCTAssertEqual(subrectangles, 320 * 128)
		XCTAssertEqual(drawn.pixels.count, image.count)
		XCTAssertEqual(differing.count, 0,
					   "\(differing.count) pixels differ, the first at \(differing.first.map { "(\($0 % width), \($0 / width))" } ?? "-")")

		let block = 64 * 1024
		let reads = upgraded.readCount

		XCTAssertLessThanOrEqual(reads, messages.bytes.count / block + 2, """
			\(reads) reads of the transport the upgrade put in place, for \(messages.bytes.count) bytes \
			holding \(subrectangles) subrectangles: it should be read in blocks of up to \(block) bytes
			""")
	}

	// MARK: - The frame

	/// Two-colour noise, row by row, from a fixed seed: SplitMix64, a public-domain generator; any
	/// fixed sequence would do, so every run sends the same frame.
	private static func noise(width: Int, height: Int) -> [UInt32] {
		var state: UInt64 = 0x5eed_5eed_5eed_5eed

		return (0..<width * height).map { _ in
			state &+= 0x9e37_79b9_7f4a_7c15

			var mixed = state
			mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
			mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
			mixed ^= mixed >> 31

			return mixed & 1 == 0 ? dark : light
		}
	}

	/// RFC 6143 7.7.4: the rectangle in 16x16 tiles, left to right and top to bottom, the last in a
	/// row and the tiles of the last row "correspondingly smaller". Each tile specifies its background
	/// (the colour most of it is), its foreground (the other), and every run of foreground pixels in a
	/// row as a subrectangle one pixel high: x-and-y-position, then width-and-height, each minus one in
	/// its four bits. Returns the number of subrectangles written.
	@discardableResult
	private static func hextile(_ pixels: [UInt32], width: Int, height: Int, into stream: inout ServerStream) -> Int {
		var written = 0

		for tileY in stride(from: 0, to: height, by: 16) {
			for tileX in stride(from: 0, to: width, by: 16) {
				let tileWidth = min(16, width - tileX)
				let tileHeight = min(16, height - tileY)

				var darkPixels = 0

				for y in tileY..<tileY + tileHeight {
					for x in tileX..<tileX + tileWidth where pixels[y * width + x] == dark {
						darkPixels += 1
					}
				}

				let background = darkPixels * 2 >= tileWidth * tileHeight ? dark : light
				let foreground = background == dark ? light : dark

				var runs = [(x: Int, y: Int, width: Int)]()

				for y in 0..<tileHeight {
					var x = 0

					while x < tileWidth {
						guard pixels[(tileY + y) * width + tileX + x] == foreground else {
							x += 1
							continue
						}

						let start = x

						while x < tileWidth, pixels[(tileY + y) * width + tileX + x] == foreground {
							x += 1
						}

						runs.append((start, y, x - start))
					}
				}

				stream.u8(2 | 4 | 8) // BackgroundSpecified, ForegroundSpecified, AnySubrects
				stream.pixel(background, bytesPerPixel: 4)
				stream.pixel(foreground, bytesPerPixel: 4)
				stream.u8(UInt8(runs.count)) // at most 8 runs in each of 16 rows

				for run in runs {
					stream.u8(UInt8(run.x << 4 | run.y))
					stream.u8(UInt8((run.width - 1) << 4)) // one pixel high: height minus one is 0
				}

				written += runs.count
			}
		}

		return written
	}

	// MARK: - The connection

	private static func settings(colorDepth: VNCConnection.Settings.ColorDepth) -> VNCConnection.Settings {
		VNCConnection.Settings(isDebugLoggingEnabled: false,
							   hostname: "scripted.invalid",
							   port: 5900,
							   isShared: true,
							   isScalingEnabled: false,
							   useDisplayLink: false,
							   inputMode: .none,
							   isClipboardRedirectionEnabled: false,
							   colorDepth: colorDepth,
							   frameEncodings: [.hextile])
	}

	/// What a connection over `transport` drew by the time the script ran out and it ended.
	private static func draw(over transport: ScriptedTransport, width: UInt16, height: UInt16) async -> DrawnFramebuffer {
		let watcher = DrawingWatcher()

		let connection = VNCConnection(settings: settings(colorDepth: .depth24Bit),
									   logger: QuietLogger(),
									   framebufferAllocator: CappedAllocator(limit: 64 * 1024 * 1024),
									   context: nil)

		connection.transportProvider = { _, _ in transport }
		connection.delegate = watcher
		connection.connect()

		// Long enough for the frame read a field at a time, as it was, so that a kit doing so fails
		// on the count above rather than on time.
		let deadline = Date().addingTimeInterval(120)

		while Date() < deadline, !watcher.result.ended {
			try? await Task.sleep(nanoseconds: 20_000_000)
		}

		connection.disconnect()

		var drawn = watcher.result.drawn

		if !watcher.result.ended {
			drawn.ending = "still connected after 120 s"
		}

		return drawn
	}
}

/// What a TLS upgrade's provider read from the transport it was handed.
private final class HandedOn: @unchecked Sendable {
	struct Stop: Error { }

	private let lock = NSLock()
	private var read: Data?

	var bytes: Data? {
		lock.lock()
		defer { lock.unlock() }

		return read
	}

	func record(_ data: Data) {
		lock.lock()
		read = data
		lock.unlock()
	}
}
