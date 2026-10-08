// The bytes a server sent, read the way the kit reads a socket, and the pieces a test needs to
// hand them to the kit's own decoders.
//
// ScriptedReader conforms to NetworkConnectionReading by its one requirement without a default,
// read(minimumLength:maximumLength:), so every other read -- readUInt8, readUInt16, readBuffered,
// readString -- is the kit's own code running over it. It never hands out more than the script
// holds; where a socket's peer would have hung up it throws EndOfScript, so a truncated stream
// ends a decoder the way a closed connection does, and a caller can tell the two apart from a
// decoder that refused what it read. A chunk limit makes it return fewer bytes than asked, as a
// socket may, so the kit's reassembly is exercised too.
//
// No XCTest in this file: Tools/fuzz compiles it into the libFuzzer harness as well.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import RoyalVNCKit

final class ScriptedReader: NetworkConnectionReading {
	/// The script ran out: what a socket reports when its peer hangs up.
	struct EndOfScript: Error { }

	private let bytes: [UInt8]
	private let chunkLimit: Int

	/// How far the kit has read.
	private(set) var offset = 0

	/// - Parameter chunkLimit: the most one read returns, however much is asked for; at least
	///   the read's minimum.
	init(_ bytes: [UInt8], chunkLimit: Int = .max) {
		self.bytes = bytes
		self.chunkLimit = max(1, chunkLimit)
	}

	convenience init(_ data: Data, chunkLimit: Int = .max) {
		self.init([UInt8](data), chunkLimit: chunkLimit)
	}

	var remaining: Int {
		bytes.count - offset
	}

	func read(minimumLength: Int,
			  maximumLength: Int) async throws -> Data {
		let minimum = max(1, minimumLength)

		guard maximumLength >= minimum,
			  remaining >= minimum else {
			offset = bytes.count

			throw EndOfScript()
		}

		let count = max(minimum, min(maximumLength, remaining, chunkLimit))
		let chunk = Data(bytes[offset..<offset + count])

		offset += count

		return chunk
	}
}

/// A logger that keeps nothing but a count of errors, so that a fuzz loop does not spend its time
/// formatting messages nobody reads.
final class QuietLogger: VNCLogger {
	var isDebugLoggingEnabled = false

	private(set) var errorCount = 0

	func logDebug(_ message: @autoclosure () -> String) { }
	func logInfo(_ message: String) { }
	func logWarning(_ message: String) { }

	func logError(_ message: String) {
		errorCount += 1
	}
}

/// Server-to-client bytes in RFC 6143's layouts (section 7: multi-byte integers big endian, PIXEL
/// in the client's pixel format, which for these depths is little endian, as the kit asks for).
struct ServerStream {
	private(set) var bytes = [UInt8]()

	init() { }

	mutating func u8(_ value: UInt8) {
		bytes.append(value)
	}

	mutating func u16(_ value: UInt16) {
		bytes.append(UInt8(value >> 8))
		bytes.append(UInt8(value & 0xff))
	}

	mutating func u32(_ value: UInt32) {
		u16(UInt16(value >> 16))
		u16(UInt16(value & 0xffff))
	}

	mutating func s32(_ value: Int32) {
		u32(UInt32(bitPattern: value))
	}

	mutating func append(_ more: [UInt8]) {
		bytes += more
	}

	mutating func append(_ more: Data) {
		bytes += [UInt8](more)
	}

	/// A pixel of `bytesPerPixel` bytes, least significant byte first.
	mutating func pixel(_ value: UInt32, bytesPerPixel: Int) {
		for index in 0..<bytesPerPixel {
			bytes.append(UInt8((value >> (8 * UInt32(index))) & 0xff))
		}
	}

	/// RFC 6143 7.6.1: the FramebufferUpdate header after its message-type byte -- padding and
	/// number-of-rectangles.
	mutating func framebufferUpdateHeader(rectangles: UInt16) {
		u8(0)
		u16(rectangles)
	}

	/// RFC 6143 7.6.1: a rectangle header.
	mutating func rectangle(x: UInt16, y: UInt16, width: UInt16, height: UInt16, encoding: Int32) {
		u16(x)
		u16(y)
		u16(width)
		u16(height)
		s32(encoding)
	}

	/// RFC 6143 7.6.2: SetColourMapEntries after its message-type byte -- padding, first-colour,
	/// number-of-colours and that many U16 RGB triples.
	mutating func setColourMapEntries(firstColour: UInt16, colours: [(UInt16, UInt16, UInt16)]) {
		u8(0)
		u16(firstColour)
		u16(UInt16(colours.count))

		for (red, green, blue) in colours {
			u16(red)
			u16(green)
			u16(blue)
		}
	}
}

/// A framebuffer as the kit makes one for a session at `depth`, in plain memory rather than an
/// IOSurface so the same code runs everywhere.
func makeTestFramebuffer(width: UInt16,
						 height: UInt16,
						 depth: UInt8,
						 logger: VNCLogger = QuietLogger()) throws -> VNCFramebuffer {
	try VNCFramebuffer(logger: logger,
					   size: .init(width: width, height: height),
					   screens: [ ],
					   pixelFormat: .init(depth: depth),
					   allocator: VNCFramebufferMallocAllocator())
}

/// A connection that is never connected, for the decoder table it builds: the same
/// `VNCConnection.encodings` a live session dispatches every rectangle through.
func makeTestEncodings(logger: VNCLogger = QuietLogger()) -> (connection: VNCConnection, encodings: Encodings) {
	let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
										  hostname: "fuzz.invalid",
										  port: 5900,
										  isShared: true,
										  isScalingEnabled: false,
										  useDisplayLink: false,
										  inputMode: .none,
										  isClipboardRedirectionEnabled: false,
										  colorDepth: .depth24Bit,
										  frameEncodings: VNCFrameEncodingType.defaultFrameEncodings)

	let connection = VNCConnection(settings: settings,
								   logger: logger,
								   framebufferAllocator: VNCFramebufferMallocAllocator(),
								   context: nil)

	return (connection, connection.encodings)
}
