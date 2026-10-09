// What a server can send a client after the handshake, made up at random and fed to the kit's own
// readers and decoders: the core that ServerToClientFuzzTests (seeded, deterministic, in the suite)
// and Tools/fuzz (libFuzzer, coverage-guided, by hand) share.
//
// A fuzz input is a framebuffer -- a depth of 8, 16 or 24 bits and a size -- and a list of records,
// each a rectangle (an encoding, a position and size, and the bytes after its header) or a whole
// message of some other type. `script` lays the records out as a server would send them: runs of
// rectangles as FramebufferUpdates (RFC 6143 7.6.1), other messages as they are. A session hands
// the script to the kit through a ScriptedReader and dispatches each message as VNCConnection's
// receive loop does (FramebufferUpdate.receive, SetColourMapEntries.receive and
// VNCFramebuffer.updateColorMap, Bell, ServerCutText, EndOfContinuousUpdates), into a real
// VNCFramebuffer, through the decoder table a VNCConnection builds, each decoder wrapped to count
// what it was fed. A resize makes a new framebuffer as the connection does, up to a budget of a
// million pixels (larger ones are counted, not made: the ceiling the kit enforces is a gigabyte).
//
// The generators lay out each encoding as RFC 6143 7.7 and rfbproto.rst's Encodings give it --
// Raw, CopyRect, RRE, CoRRE, Hextile, zlib, Tight, ZRLE -- and the pseudo-encodings and messages
// the kit reads (DesktopSize, ExtendedDesktopSize, Cursor, DesktopName, LastRect;
// SetColourMapEntries, ServerCutText and its extended form, Bell, EndOfContinuousUpdates), mostly
// well formed, with the numbers a hostile server would try (0, the edges of the framebuffer, of a
// tile, of the colour map and of the size ceiling, 0xFFFF) and then mutated: fields set to edge
// values, bytes flipped, payloads cut short or run long. Compressed data is a stored-block zlib
// stream per stream the kit keeps (ZlibStoredStream), so what the decoders inflate is the
// generator's, and sometimes plain noise.
//
// No XCTest here: Tools/fuzz compiles this file into the libFuzzer harness as well.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import RoyalVNCKit

// MARK: - Deterministic randomness

/// splitmix64: the same seed, the same sequence, on every platform.
struct FRng {
	var state: UInt64

	init(_ seed: UInt64) {
		state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15

		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB

		return z ^ (z >> 31)
	}

	/// 0 ..< n.
	mutating func int(_ n: Int) -> Int {
		n <= 1 ? 0 : Int(next() % UInt64(n))
	}

	/// lower ... upper.
	mutating func int(_ range: ClosedRange<Int>) -> Int {
		range.lowerBound + int(range.upperBound - range.lowerBound + 1)
	}

	mutating func chance(_ p: Double) -> Bool {
		Double(next() % 1_000_000) / 1_000_000.0 < p
	}

	mutating func pick<T>(_ values: [T]) -> T {
		values[int(values.count)]
	}

	mutating func byte() -> UInt8 {
		UInt8(truncatingIfNeeded: next())
	}

	mutating func bytes(_ count: Int) -> [UInt8] {
		(0..<max(0, count)).map { _ in byte() }
	}

	/// A U16 a hostile server might try.
	mutating func edge16() -> UInt16 {
		let random = UInt16(truncatingIfNeeded: next())

		return pick([0, 1, 2, 15, 16, 17, 63, 64, 65, 127, 128, 255, 256, 0x7fff, 0x8000, 0xfffe, 0xffff, random])
	}
}

// MARK: - The input

/// A framebuffer and the records a server sends to it.
struct FuzzInput {
	enum Record {
		/// A rectangle: its header (RFC 6143 7.6.1) and the bytes after it.
		case rectangle(encoding: Int32, x: UInt16, y: UInt16, width: UInt16, height: UInt16, payload: [UInt8])

		/// A whole server-to-client message, its message-type byte first.
		case message([UInt8])
	}

	var depth: UInt8
	var width: UInt16
	var height: UInt16

	/// The most bytes one read returns, as a socket may return fewer than asked for.
	var chunkLimit: Int

	var records: [Record]

	/// The records as a server sends them: each run of rectangles one FramebufferUpdate.
	var script: [UInt8] {
		var stream = ServerStream()
		var run = [Record]()

		func flush() {
			var start = 0

			while start < run.count {
				let count = min(run.count - start, Int(UInt16.max))

				stream.u8(0) // FramebufferUpdate
				stream.framebufferUpdateHeader(rectangles: UInt16(count))

				for case .rectangle(let encoding, let x, let y, let width, let height, let payload) in run[start..<start + count] {
					stream.rectangle(x: x, y: y, width: width, height: height, encoding: encoding)
					stream.append(payload)
				}

				start += count
			}

			run.removeAll()
		}

		for record in records {
			switch record {
				case .rectangle:
					run.append(record)
				case .message(let bytes):
					flush()
					stream.append(bytes)
			}
		}

		flush()

		return stream.bytes
	}
}

// MARK: - Families: what a libFuzzer run keeps to

/// A part of what a server can send, for a libFuzzer run to spend its time on: the encodings its
/// rectangles may have, and whether other messages may come between them.
struct FuzzFamily {
	let name: String
	let encodings: [Int32]
	let messages: Bool
	let depths: [UInt8]

	static let all: [FuzzFamily] = [
		.init(name: "raw-copyrect", encodings: [0, 1], messages: false, depths: [24, 16, 8]),
		.init(name: "rre-corre", encodings: [2, 4], messages: false, depths: [24, 16, 8]),
		.init(name: "hextile", encodings: [5], messages: false, depths: [24, 16, 8]),
		.init(name: "zlib", encodings: [6], messages: false, depths: [24, 16, 8]),
		.init(name: "zrle", encodings: [16], messages: false, depths: [24]),
		.init(name: "tight", encodings: [7], messages: false, depths: [24, 16]),
		.init(name: "pseudo", encodings: [-223, -308, -239, -307, -224, 0], messages: false, depths: [24, 16, 8]),
		.init(name: "messages", encodings: [0, 1, 2, 4, 5, 6, 7, 16, -223, -308, -239, -307, -224, 3, 99], messages: true, depths: [8, 24, 16])
	]

	static func named(_ name: String) -> FuzzFamily? {
		all.first { $0.name == name }
	}
}

extension FuzzInput {
	/// A libFuzzer input, as bytes: [depth][chunk][width u16][height u16], then records, each
	/// [0][encoding index][x][y][width][height][length u16][payload] or [1][length u16][message].
	/// The encoding is the family's, picked by index, so that whatever libFuzzer does to the
	/// bytes the run keeps to its family. Read leniently: a record cut short ends the input.
	init(fuzzBytes bytes: [UInt8], family: FuzzFamily) {
		var index = 0

		func u8() -> UInt8? {
			guard index < bytes.count else {
				return nil
			}

			defer { index += 1 }

			return bytes[index]
		}

		func u16() -> UInt16? {
			guard let high = u8(), let low = u8() else {
				return nil
			}

			return UInt16(high) << 8 | UInt16(low)
		}

		func take(_ count: Int) -> [UInt8] {
			let end = min(bytes.count, index + count)
			defer { index = end }

			return Array(bytes[index..<end])
		}

		depth = family.depths[Int(u8() ?? 0) % family.depths.count]
		chunkLimit = [Int.max, 1, 2, 3, 7, 16, 4096][Int(u8() ?? 0) % 7]

		var width = u16() ?? 64
		var height = u16() ?? 64

		// A framebuffer of up to a million pixels, the run's budget: wide or tall, never both.
		while Int(width) * Int(height) > FuzzSession.allocationBudget {
			height /= 2
		}

		self.width = width
		self.height = height

		records = []

		while let tag = u8() {
			if tag % 2 == 1, family.messages {
				guard let length = u16() else {
					break
				}

				records.append(.message(take(Int(length))))
			} else {
				guard let selector = u8(),
					  let x = u16(), let y = u16(), let width = u16(), let height = u16(),
					  let length = u16() else {
					break
				}

				records.append(.rectangle(encoding: family.encodings[Int(selector) % family.encodings.count],
										  x: x, y: y, width: width, height: height,
										  payload: take(Int(length))))
			}
		}
	}

	/// The same layout, written: what the generators give libFuzzer as seeds.
	func fuzzBytes(family: FuzzFamily) -> [UInt8] {
		var stream = ServerStream()

		stream.u8(UInt8(family.depths.firstIndex(of: depth) ?? 0))
		stream.u8(UInt8([Int.max, 1, 2, 3, 7, 16, 4096].firstIndex(of: chunkLimit) ?? 0))
		stream.u16(width)
		stream.u16(height)

		for record in records {
			switch record {
				case .rectangle(let encoding, let x, let y, let width, let height, let payload):
					guard let selector = family.encodings.firstIndex(of: encoding) else {
						continue
					}

					stream.u8(0)
					stream.u8(UInt8(selector))
					stream.u16(x); stream.u16(y); stream.u16(width); stream.u16(height)
					stream.u16(UInt16(min(payload.count, Int(UInt16.max))))
					stream.append(Array(payload.prefix(Int(UInt16.max))))
				case .message(let bytes):
					guard family.messages else {
						continue
					}

					stream.u8(1)
					stream.u16(UInt16(min(bytes.count, Int(UInt16.max))))
					stream.append(Array(bytes.prefix(Int(UInt16.max))))
			}
		}

		return stream.bytes
	}
}

// MARK: - What each decoder was fed

/// Counts, per encoding and per message type: how many reached the kit, how many bytes the kit
/// read for them, and how each ended.
final class FuzzTally {
	struct Line {
		var fed = 0
		var bytes = 0
		var outcomes = [String: Int]()
	}

	private(set) var decoders = [Int64: Line]()
	private(set) var messages = [UInt8: Line]()

	private(set) var sessions = 0
	private(set) var sessionOutcomes = [String: Int]()

	var resizesMade = 0
	var resizesOverBudget = 0
	var largestFramebufferPixels = 0

	func decoder(_ encoding: VNCEncodingType, bytes: Int, outcome: String) {
		decoders[encoding.rawValue, default: Line()].fed += 1
		decoders[encoding.rawValue, default: Line()].bytes += bytes
		decoders[encoding.rawValue, default: Line()].outcomes[outcome, default: 0] += 1
	}

	/// The message types the kit reads; any other is counted under `unknownMessageType`.
	static let knownMessageTypes: Set<UInt8> = [0, 1, 2, 3, 150]
	static let unknownMessageType: UInt8 = 255

	func message(_ type: UInt8, bytes: Int, outcome: String) {
		let type = Self.knownMessageTypes.contains(type) ? type : Self.unknownMessageType

		messages[type, default: Line()].fed += 1
		messages[type, default: Line()].bytes += bytes
		messages[type, default: Line()].outcomes[outcome, default: 0] += 1
	}

	func session(_ outcome: String) {
		sessions += 1
		sessionOutcomes[outcome, default: 0] += 1
	}

	/// How an error ended something: "decoded" when nothing was thrown, "truncated" where the
	/// script ran out, else the error's case.
	static func outcome(of error: Error?) -> String {
		guard let error else {
			return "decoded"
		}

		if error is ScriptedReader.EndOfScript {
			return "truncated"
		}

		if let vncError = error as? VNCError {
			switch vncError {
				case .protocol(let underlying): return "refused " + caseName(underlying)
				case .connection(let underlying): return "connection " + caseName(underlying)
				case .authentication(let underlying): return "authentication " + caseName(underlying)
			}
		}

		return "other \(type(of: error))"
	}

	private static func caseName(_ value: Any) -> String {
		String("\(value)".prefix { $0 != "(" })
	}

	static func encodingName(_ rawValue: Int64) -> String {
		if let encoding = VNCEncodingType(rawValue: rawValue) {
			if let frame = VNCFrameEncodingType(rawValue: encoding) {
				return frame.description
			}

			if let pseudo = VNCPseudoEncodingType(rawValue: encoding) {
				return "\(pseudo)"
			}
		}

		return "encoding \(rawValue)"
	}

	static func messageName(_ type: UInt8) -> String {
		switch type {
			case 0: "FramebufferUpdate"
			case 1: "SetColourMapEntries"
			case 2: "Bell"
			case 3: "ServerCutText"
			case 150: "EndOfContinuousUpdates"
			default: "Any other message type"
		}
	}

	/// The report: one line per decoder and per message type, most fed first.
	func report() -> String {
		var lines = [String]()

		func describe(_ line: Line) -> String {
			let outcomes = line.outcomes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }

			return "fed \(line.fed), \(line.bytes) bytes read: " + outcomes.joined(separator: ", ")
		}

		for (encoding, line) in decoders.sorted(by: { $0.value.fed > $1.value.fed }) {
			lines.append("  \(Self.encodingName(encoding)): \(describe(line))")
		}

		for (type, line) in messages.sorted(by: { $0.value.fed > $1.value.fed }) {
			lines.append("  \(Self.messageName(type)): \(describe(line))")
		}

		let sessionLine = sessionOutcomes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")

		lines.append("  sessions \(sessions): \(sessionLine)")
		lines.append("  resizes made \(resizesMade), over the run's budget \(resizesOverBudget); largest framebuffer \(largestFramebufferPixels) pixels")

		return lines.joined(separator: "\n")
	}
}

/// A decoder from the table, counted.
final class CountingFrameEncoding: VNCFrameEncoding {
	let encodingType: VNCEncodingType

	private let decoder: VNCFrameEncoding
	private let tally: FuzzTally

	init(_ decoder: VNCFrameEncoding, tally: FuzzTally) {
		self.encodingType = decoder.encodingType
		self.decoder = decoder
		self.tally = tally
	}

	func decodeRectangle(_ rectangle: VNCProtocol.Rectangle,
						 framebuffer: VNCFramebuffer,
						 connection: NetworkConnectionReading,
						 logger: VNCLogger) async throws {
		let start = (connection as? ScriptedReader)?.offset ?? 0

		do {
			try await decoder.decodeRectangle(rectangle, framebuffer: framebuffer, connection: connection, logger: logger)

			tally.decoder(.init(integerLiteral: Int64(rectangle.encodingType)),
						  bytes: ((connection as? ScriptedReader)?.offset ?? 0) - start,
						  outcome: FuzzTally.outcome(of: nil))
		} catch {
			tally.decoder(.init(integerLiteral: Int64(rectangle.encodingType)),
						  bytes: ((connection as? ScriptedReader)?.offset ?? 0) - start,
						  outcome: FuzzTally.outcome(of: error))

			throw error
		}
	}
}

/// A pseudo-encoding from the table, counted.
final class CountingPseudoEncoding: VNCReceivablePseudoEncoding {
	let encodingType: VNCEncodingType

	private let decoder: VNCReceivablePseudoEncoding
	private let tally: FuzzTally

	init(_ decoder: VNCReceivablePseudoEncoding, tally: FuzzTally) {
		self.encodingType = decoder.encodingType
		self.decoder = decoder
		self.tally = tally
	}

	func receive(_ rectangle: VNCProtocol.Rectangle,
				 framebuffer: VNCFramebuffer,
				 connection: NetworkConnectionReading,
				 logger: VNCLogger) async throws {
		let start = (connection as? ScriptedReader)?.offset ?? 0

		do {
			try await decoder.receive(rectangle, framebuffer: framebuffer, connection: connection, logger: logger)

			tally.decoder(.init(integerLiteral: Int64(rectangle.encodingType)),
						  bytes: ((connection as? ScriptedReader)?.offset ?? 0) - start,
						  outcome: FuzzTally.outcome(of: nil))
		} catch {
			tally.decoder(.init(integerLiteral: Int64(rectangle.encodingType)),
						  bytes: ((connection as? ScriptedReader)?.offset ?? 0) - start,
						  outcome: FuzzTally.outcome(of: error))

			throw error
		}
	}
}

// MARK: - A session

/// One connection's worth of server-to-client messages, decoded as VNCConnection decodes them.
final class FuzzSession: VNCFramebufferDelegate {
	/// The most pixels a framebuffer this run makes may have; a resize to more is counted and not
	/// made. A million: four megabytes at four bytes a pixel.
	static let allocationBudget = 1 << 20

	let logger = QuietLogger()
	let tally: FuzzTally
	let encodings: Encodings

	private(set) var framebuffer: VNCFramebuffer

	private let connection: VNCConnection

	init(depth: UInt8, width: UInt16, height: UInt16, tally: FuzzTally) throws {
		self.tally = tally

		framebuffer = try makeTestFramebuffer(width: width, height: height, depth: depth, logger: logger)

		let (connection, table) = makeTestEncodings(logger: logger)

		self.connection = connection

		var wrapped = Encodings()

		for (type, encoding) in table {
			if let frame = encoding as? VNCFrameEncoding {
				wrapped[type] = CountingFrameEncoding(frame, tally: tally)
			} else if let pseudo = encoding as? VNCReceivablePseudoEncoding {
				wrapped[type] = CountingPseudoEncoding(pseudo, tally: tally)
			} else {
				// LastRect, which FramebufferUpdate.receive recognises by its type, and the
				// pseudo-encodings a client only sends.
				wrapped[type] = encoding
			}
		}

		encodings = wrapped

		tally.largestFramebufferPixels = max(tally.largestFramebufferPixels, Int(width) * Int(height))

		framebuffer.delegate = self
	}

	/// Hands the script to the kit message by message until it runs out or the kit refuses one,
	/// and says which.
	func run(script: [UInt8], chunkLimit: Int) async -> String {
		let reader = ScriptedReader(script, chunkLimit: chunkLimit)

		while true {
			let messageType: UInt8

			do {
				messageType = try await VNCProtocol.ServerToClientMessage.receive(connection: reader).messageType
			} catch {
				return "ran to its end"
			}

			let start = reader.offset

			do {
				switch messageType {
					case VNCProtocol.FramebufferUpdate.messageType:
						_ = try await VNCProtocol.FramebufferUpdate.receive(connection: reader,
																			framebuffer: framebuffer,
																			encodings: encodings,
																			logger: logger)

					case VNCProtocol.SetColourMapEntries.messageType:
						let entries = try await VNCProtocol.SetColourMapEntries.receive(connection: reader,
																						logger: logger)

						try framebuffer.updateColorMap(entries)

					case VNCProtocol.Bell.messageType:
						_ = try await VNCProtocol.Bell.receive(connection: reader, logger: logger)

					case VNCProtocol.ServerCutText.messageType:
						_ = try await VNCProtocol.ServerCutText.receive(connection: reader, logger: logger)

					case VNCProtocol.EndOfContinuousUpdates.messageType:
						break

					default:
						throw VNCError.protocol(.unsupportedServerToClientMessage(messageType: messageType))
				}

				tally.message(messageType, bytes: reader.offset - start, outcome: FuzzTally.outcome(of: nil))
			} catch {
				let outcome = FuzzTally.outcome(of: error)

				tally.message(messageType, bytes: reader.offset - start, outcome: outcome)

				return outcome
			}
		}
	}

	// MARK: VNCFramebufferDelegate

	func framebuffer(_ framebuffer: VNCFramebuffer, didUpdateRegion updatedRegion: VNCRegion) { }
	func framebuffer(_ framebuffer: VNCFramebuffer, didUpdateDesktopName newDesktopName: String) { }
	func framebuffer(_ framebuffer: VNCFramebuffer, didUpdateCursor cursor: VNCCursor) { }

	/// As VNCConnection.recreateFramebuffer, within the run's budget.
	func framebuffer(_ framebuffer: VNCFramebuffer, sizeDidChange newSize: VNCSize, screens newScreens: [VNCScreen]) {
		let pixels = Int(newSize.width) * Int(newSize.height)

		guard pixels <= Self.allocationBudget else {
			tally.resizesOverBudget += 1

			return
		}

		guard let replacement = try? VNCFramebuffer(logger: logger,
													size: newSize,
													screens: newScreens,
													pixelFormat: framebuffer.sourcePixelFormat,
													allocator: VNCFramebufferMallocAllocator()) else {
			return
		}

		replacement.inheritColorMap(from: framebuffer)

		self.framebuffer.delegate = nil
		replacement.delegate = self
		self.framebuffer = replacement

		tally.resizesMade += 1
		tally.largestFramebufferPixels = max(tally.largestFramebufferPixels, pixels)
	}
}

// MARK: - Generators

/// Makes fuzz inputs: mostly well formed, then mutated.
struct FuzzGenerator {
	var rng: FRng

	/// The zlib streams the kit keeps for a connection, as the generator models them: one for
	/// Zlib, one for ZRLE, four for Tight.
	private var zlibStream = ZlibStoredStream()
	private var zrleStream = ZlibStoredStream()
	private var tightStreams = [ZlibStoredStream](repeating: ZlibStoredStream(), count: 4)

	private var depth: UInt8 = 24
	private var width = 64
	private var height = 64

	init(seed: UInt64) {
		rng = FRng(seed)
	}

	private var bytesPerPixel: Int {
		depth > 16 ? 4 : (depth > 8 ? 2 : 1)
	}

	/// A whole input, of the encodings `family` keeps to, or of any.
	mutating func input(family: FuzzFamily? = nil) -> FuzzInput {
		zlibStream = ZlibStoredStream()
		zrleStream = ZlibStoredStream()
		tightStreams = [ZlibStoredStream](repeating: ZlibStoredStream(), count: 4)

		depth = family.map { rng.pick($0.depths) } ?? rng.pick([24, 24, 24, 16, 8])

		switch rng.int(20) {
			case 0: (width, height) = (65535, rng.int(1...16))
			case 1: (width, height) = (rng.int(1...16), 65535)
			case 2: (width, height) = (0, rng.int(0...8))
			case 3: (width, height) = (rng.int(1...1024), rng.int(1...1024))
			default: (width, height) = (rng.int(1...160), rng.int(1...120))
		}

		while width * height > FuzzSession.allocationBudget {
			height /= 2
		}

		let encodings = family?.encodings ?? [0, 1, 2, 4, 5, 6, 7, 16, -223, -308, -239, -307, -224]
		let messages = family?.messages ?? true

		var records = [FuzzInput.Record]()

		for _ in 0..<rng.int(1...8) {
			if messages, rng.chance(0.25) {
				records.append(.message(message()))
			} else {
				records.append(rectangle(encoding: rng.pick(encodings)))
			}
		}

		return .init(depth: depth,
					 width: UInt16(width),
					 height: UInt16(height),
					 chunkLimit: rng.chance(0.8) ? .max : rng.pick([1, 2, 3, 7, 16, 4096]),
					 records: records)
	}

	// MARK: Rectangles

	/// A rectangle of `encoding`: a position and size, mostly inside the framebuffer, and a
	/// payload in the encoding's layout, then perhaps mutated.
	mutating func rectangle(encoding: Int32) -> FuzzInput.Record {
		var (x, y, w, h) = place(encoding: encoding)

		var payload: [UInt8]

		switch encoding {
			case 0: payload = raw(w, h)
			case 1: payload = copyRect()
			case 2: payload = rre(w, h, compact: false)
			case 4: payload = rre(w, h, compact: true)
			case 5: payload = hextile(w, h)
			case 6: payload = zlib(w, h)
			case 7: payload = tight(w, h)
			case 16: payload = zrle(w, h)
			case -223: (w, h) = desktopSize(); payload = []
			case -308: (w, h) = desktopSize(); payload = extendedDesktopSize(w, h)
			case -239: (x, y, w, h) = (rng.int(0...32), rng.int(0...32), rng.int(0...40), rng.int(0...40)); payload = cursor(w, h)
			case -307: (x, y, w, h) = rng.chance(0.9) ? (0, 0, 0, 0) : (rng.int(0...3), 0, 0, 0); payload = desktopName()
			default: payload = rng.bytes(rng.int(0...32))
		}

		mutate(&payload)

		if rng.chance(0.03) {
			x = Int(rng.edge16())
		}

		if rng.chance(0.03) {
			w = Int(rng.edge16())
		}

		return .rectangle(encoding: encoding,
						  x: UInt16(truncatingIfNeeded: x), y: UInt16(truncatingIfNeeded: y),
						  width: UInt16(truncatingIfNeeded: w), height: UInt16(truncatingIfNeeded: h),
						  payload: payload)
	}

	/// Where a rectangle goes: mostly a small one inside the framebuffer, sometimes all of it,
	/// one at its right or bottom edge, one as wide or as high as the framebuffer, an empty one, or
	/// one reaching outside.
	private mutating func place(encoding: Int32) -> (Int, Int, Int, Int) {
		let maxSide = encoding == 0 || encoding == 6 || encoding == 7 ? 48 : 96

		// At a framebuffer 65535 pixels wide or tall, the rectangles that matter most reach its far
		// edge, where a decoder's tile count and positions are largest: often, there, one as wide
		// (or as high) as the framebuffer, a pixel or two across the other way.
		if width > 4096 || height > 4096, rng.chance(0.3) {
			return width >= height
				? (0, rng.int(0...max(0, height - 2)), width, min(height, rng.int(1...2)))
				: (rng.int(0...max(0, width - 2)), 0, min(width, rng.int(1...2)), height)
		}

		switch rng.int(13) {
			case 0:
				return (0, 0, min(width, maxSide * 2), min(height, maxSide))
			case 1:
				let w = min(width, rng.int(1...maxSide))
				return (width - w, rng.int(0...max(0, height - 1)), w, min(height, rng.int(1...4)))
			case 2:
				let h = min(height, rng.int(1...maxSide))
				return (rng.int(0...max(0, width - 1)), height - h, min(width, rng.int(1...4)), h)
			case 3:
				return (rng.int(0...width), rng.int(0...height), 0, rng.int(0...3))
			case 4:
				return (rng.int(0...width), rng.int(0...height), rng.int(1...maxSide), rng.int(1...maxSide))
			case 5:
				// The whole width or height, a pixel or two across: at a 65535-pixel framebuffer, a
				// decoder's tile count and last tile are at their largest.
				return rng.chance(0.5)
					? (0, rng.int(0...max(0, height - 2)), width, min(height, rng.int(1...2)))
					: (rng.int(0...max(0, width - 2)), 0, min(width, rng.int(1...2)), height)
			default:
				let w = min(width, rng.int(1...maxSide))
				let h = min(height, rng.int(1...maxSide))

				return (rng.int(0...max(0, width - w)), rng.int(0...max(0, height - h)), w, h)
		}
	}

	private mutating func pixel() -> [UInt8] {
		rng.bytes(bytesPerPixel)
	}

	/// RFC 6143 7.7.1: width*height pixels.
	private mutating func raw(_ w: Int, _ h: Int) -> [UInt8] {
		rng.bytes(w * h * bytesPerPixel)
	}

	/// 7.7.2: a source position, mostly inside the framebuffer.
	private mutating func copyRect() -> [UInt8] {
		var stream = ServerStream()

		stream.u16(rng.chance(0.85) ? UInt16(rng.int(0...width)) : rng.edge16())
		stream.u16(rng.chance(0.85) ? UInt16(rng.int(0...height)) : rng.edge16())

		return stream.bytes
	}

	/// 7.7.3 (RRE), and rfbproto.rst's CoRRE with one-byte positions: a count, a background
	/// pixel, and that many sub-rectangles, mostly inside the rectangle.
	private mutating func rre(_ w: Int, _ h: Int, compact: Bool) -> [UInt8] {
		var stream = ServerStream()
		let count = rng.chance(0.95) ? rng.int(0...12) : Int(rng.pick([0x100, 0xffff, 0x7fff_ffff, 0xffff_ffff] as [UInt32]))
		let sent = min(count, 12)

		stream.u32(UInt32(truncatingIfNeeded: count))
		stream.append(pixel())

		for _ in 0..<sent {
			stream.append(pixel())

			var sx = rng.int(0...max(0, w - 1))
			var sy = rng.int(0...max(0, h - 1))
			var sw = rng.int(0...max(0, w - sx))
			var sh = rng.int(0...max(0, h - sy))

			if rng.chance(0.1) {
				switch rng.int(4) {
					case 0: sx = Int(rng.edge16())
					case 1: sy = Int(rng.edge16())
					case 2: sw = Int(rng.edge16())
					default: sh = w - sx + 1
				}
			}

			if compact {
				[sx, sy, sw, sh].forEach { stream.u8(UInt8(truncatingIfNeeded: $0)) }
			} else {
				[sx, sy, sw, sh].forEach { stream.u16(UInt16(truncatingIfNeeded: $0)) }
			}
		}

		return stream.bytes
	}

	/// 7.7.4: 16x16 tiles in order, each a subencoding mask and what it says follows.
	private mutating func hextile(_ w: Int, _ h: Int) -> [UInt8] {
		var stream = ServerStream()

		for tileY in stride(from: 0, to: h, by: 16) {
			for tileX in stride(from: 0, to: w, by: 16) {
				let tw = min(16, w - tileX)
				let th = min(16, h - tileY)

				var mask = UInt8(rng.int(0...31))

				if rng.chance(0.05) {
					mask = rng.byte()
				}

				stream.u8(mask)

				if mask & 1 != 0 {
					stream.append(rng.bytes(tw * th * bytesPerPixel))

					continue
				}

				if mask & 2 != 0 { stream.append(pixel()) }
				if mask & 4 != 0 { stream.append(pixel()) }

				if mask & 8 != 0 {
					let count = rng.int(0...6)

					stream.u8(UInt8(count))

					for _ in 0..<count {
						if mask & 16 != 0 { stream.append(pixel()) }

						var sx = rng.int(0...max(0, tw - 1))
						var sy = rng.int(0...max(0, th - 1))
						var sw = rng.int(1...max(1, tw - sx))
						var sh = rng.int(1...max(1, th - sy))

						if rng.chance(0.08) {
							(sx, sy, sw, sh) = (rng.int(0...15), rng.int(0...15), rng.int(1...16), rng.int(1...16))
						}

						stream.u8(UInt8(sx << 4 | sy))
						stream.u8(UInt8((sw - 1) << 4 | (sh - 1)))
					}
				}
			}
		}

		return stream.bytes
	}

	/// A U32 length and zlib data (zlib Encoding, rfbproto.rst; ZRLE, 7.7.6): mostly a chunk of
	/// the session's stream, sometimes noise, sometimes a lying length.
	private mutating func zlibFramed(_ inflated: [UInt8], stream: inout ZlibStoredStream) -> [UInt8] {
		var out = ServerStream()
		let chunk = rng.chance(0.95) ? stream.chunk(inflated) : rng.bytes(rng.int(0...64))
		let length = rng.chance(0.95) ? UInt32(chunk.count) : UInt32(truncatingIfNeeded: rng.next())

		out.u32(length)
		out.append(chunk)

		return out.bytes
	}

	private mutating func zlib(_ w: Int, _ h: Int) -> [UInt8] {
		let pixels = w * h * bytesPerPixel
		let inflated = rng.bytes(rng.chance(0.9) ? pixels : rng.int(0...pixels + 8))

		var stream = zlibStream
		let framed = zlibFramed(inflated, stream: &stream)

		zlibStream = stream

		return framed
	}

	/// 7.7.5 and 7.7.6: 64x64 tiles, each a subencoding and its data, in CPIXELs of 3 bytes.
	private mutating func zrle(_ w: Int, _ h: Int) -> [UInt8] {
		var tiles = [UInt8]()

		for tileY in stride(from: 0, to: h, by: 64) {
			for tileX in stride(from: 0, to: w, by: 64) {
				let tw = min(64, w - tileX)
				let th = min(64, h - tileY)

				tiles += zrleTile(tw, th)
			}
		}

		// Sometimes the tiles end early, or more follows them: 7.7.6 has the zlib data be the
		// tiles, and a decoder reading past what it inflated, or not reading it all, is wrong.
		if rng.chance(0.05), !tiles.isEmpty {
			if rng.chance(0.7) {
				tiles.removeLast(rng.int(1...min(8, tiles.count)))
			} else {
				tiles += rng.bytes(rng.int(1...8))
			}
		}

		var stream = zrleStream
		let framed = zlibFramed(tiles, stream: &stream)

		zrleStream = stream

		return framed
	}

	private mutating func zrleTile(_ tw: Int, _ th: Int) -> [UInt8] {
		var out = [UInt8]()
		let cpixel = 3

		func runLength(_ length: Int) -> [UInt8] {
			var remaining = length - 1
			var bytes = [UInt8]()

			while remaining >= 255 {
				bytes.append(255)
				remaining -= 255
			}

			bytes.append(UInt8(remaining))

			return bytes
		}

		switch rng.int(8) {
			case 0:
				out = [0] + rng.bytes(tw * th * cpixel)
			case 1:
				out = [1] + rng.bytes(cpixel)
			case 2, 3:
				let size = rng.int(2...16)
				let bits = size <= 2 ? 1 : (size <= 4 ? 2 : 4)
				let rowBytes = (tw * bits + 7) / 8

				out = [UInt8(size)] + rng.bytes(size * cpixel)

				for _ in 0..<th {
					for _ in 0..<rowBytes {
						var byte: UInt8 = 0

						for slot in 0..<(8 / bits) {
							let index = rng.chance(0.97) ? rng.int(0...size - 1) : rng.int(0...(1 << bits) - 1)

							byte |= UInt8(index) << UInt8(8 - bits * (slot + 1))
						}

						out.append(byte)
					}
				}
			case 4:
				out = [128]

				var done = 0

				while done < tw * th {
					let length = min(tw * th - done, rng.int(1...300))

					out += rng.bytes(cpixel) + runLength(length)
					done += length
				}
			case 5, 6:
				let size = rng.int(2...127)

				out = [UInt8(128 + size)] + rng.bytes(size * cpixel)

				var done = 0

				while done < tw * th {
					let index = rng.chance(0.98) ? rng.int(0...size - 1) : rng.int(0...127)
					let length = min(tw * th - done, rng.int(1...40))

					if length == 1 {
						out.append(UInt8(index))
					} else {
						out.append(UInt8(index | 128))
						out += runLength(length)
					}

					done += length
				}
			default:
				let random = rng.byte()

				out = [rng.pick([17, 100, 127, 129, random])] + rng.bytes(rng.int(0...16))
		}

		return out
	}

	/// rfbproto.rst's Tight Encoding: a compression-control byte, then a fill, a JPEG, or basic
	/// compression with the copy, palette or gradient filter, its data compressed past 12 bytes.
	private mutating func tight(_ w: Int, _ h: Int) -> [UInt8] {
		var out = [UInt8]()
		let tPixel = depth == 24 ? 3 : bytesPerPixel

		func compactLength(_ length: Int) -> [UInt8] {
			var bytes = [UInt8(length & 0x7f)]

			if length > 0x7f {
				bytes[0] |= 0x80
				bytes.append(UInt8((length >> 7) & 0x7f))

				if length > 0x3fff {
					bytes[1] |= 0x80
					bytes.append(UInt8((length >> 14) & 0xff))
				}
			}

			return bytes
		}

		var resets: UInt8 = 0

		if rng.chance(0.2) {
			resets = UInt8(rng.int(0...15))

			for index in 0..<4 where resets & (1 << index) != 0 {
				tightStreams[index] = ZlibStoredStream()
			}
		}

		func data(_ bytes: [UInt8], streamID: Int) -> [UInt8] {
			guard bytes.count >= 12 else {
				return bytes
			}

			let chunk = rng.chance(0.95) ? tightStreams[streamID].chunk(bytes) : rng.bytes(rng.int(0...40))

			return compactLength(chunk.count) + chunk
		}

		switch rng.int(10) {
			case 0, 1:
				out = [0x80 | resets] + rng.bytes(tPixel)
			case 2:
				var jpeg = [UInt8]([0xff, 0xd8]) + rng.bytes(rng.int(0...200))

				if rng.chance(0.5) {
					jpeg += [0xff, 0xd9]
				}

				out = [0x90 | resets] + compactLength(jpeg.count) + jpeg
			case 3:
				out = [0xa0 | resets] + rng.bytes(8)
			default:
				let streamID = rng.int(0...3)
				let filter = rng.int(0...3)

				out = [UInt8(streamID << 4) | resets]

				switch filter {
					case 1:
						let size = rng.chance(0.3) ? 2 : rng.int(1...256)
						let indexBytes = size == 2 ? (w + 7) / 8 * h : w * h
						var indices = size == 2 ? rng.bytes(indexBytes) : (0..<indexBytes).map { _ in UInt8(rng.int(0...size - 1)) }

						if rng.chance(0.05), !indices.isEmpty {
							indices[rng.int(indices.count)] = rng.byte()
						}

						out[0] |= 0x40
						out += [1, UInt8(size - 1)] + rng.bytes(size * tPixel) + data(indices, streamID: streamID)
					case 2:
						out[0] |= 0x40
						out += [2] + data(rng.bytes(w * h * 3), streamID: streamID)
					case 3:
						out[0] |= 0x40
						out += [rng.pick([3, 7, 0xff])] + rng.bytes(8)
					default:
						if rng.chance(0.5) {
							out[0] |= 0x40
							out.append(0)
						}

						out += data(rng.bytes(w * h * tPixel), streamID: streamID)
				}
		}

		return out
	}

	/// 7.8.2: DesktopSize's width and height are the new framebuffer's.
	private mutating func desktopSize() -> (Int, Int) {
		switch rng.int(10) {
			case 0: return (16384, 16384)
			case 1: return (16384, 16385)
			case 2: return (65535, 65535)
			case 3: return (65535, rng.int(1...16))
			case 4: return (0, rng.int(0...4))
			default: return (rng.int(1...400), rng.int(1...300))
		}
	}

	/// rfbproto.rst's ExtendedDesktopSize: a count, padding, and that many 16-byte screens.
	private mutating func extendedDesktopSize(_ w: Int, _ h: Int) -> [UInt8] {
		var stream = ServerStream()
		let count = rng.chance(0.9) ? rng.int(0...4) : 255

		stream.u8(UInt8(count))
		stream.append([0, 0, 0])

		for _ in 0..<min(count, 6) {
			stream.u32(UInt32(truncatingIfNeeded: rng.next()))
			stream.u16(UInt16(rng.int(0...max(0, w)))); stream.u16(UInt16(rng.int(0...max(0, h))))
			stream.u16(rng.chance(0.9) ? UInt16(truncatingIfNeeded: w) : rng.edge16())
			stream.u16(rng.chance(0.9) ? UInt16(truncatingIfNeeded: h) : rng.edge16())
			stream.u32(0)
		}

		return stream.bytes
	}

	/// 7.8.1: width*height pixels, then a mask of floor((width+7)/8) bytes a row.
	private mutating func cursor(_ w: Int, _ h: Int) -> [UInt8] {
		rng.bytes(w * h * bytesPerPixel + (w + 7) / 8 * h)
	}

	/// rfbproto.rst's DesktopName: a U32 length and that much UTF-8.
	private mutating func desktopName() -> [UInt8] {
		var stream = ServerStream()
		let name = rng.chance(0.8) ? Array("desktop \(rng.int(0...999))".utf8) : rng.bytes(rng.int(0...40))

		stream.u32(rng.chance(0.95) ? UInt32(name.count) : UInt32(truncatingIfNeeded: rng.next()))
		stream.append(name)

		return stream.bytes
	}

	// MARK: Messages

	/// A message other than a FramebufferUpdate, its type byte first.
	mutating func message() -> [UInt8] {
		var stream = ServerStream()

		switch rng.int(10) {
			case 0, 1, 2:
				// 7.6.2: SetColourMapEntries.
				let first = rng.chance(0.5) ? UInt16(rng.int(0...300)) : rng.edge16()
				let count = rng.chance(0.9) ? rng.int(0...300) : Int(rng.edge16())
				let sent = rng.chance(0.95) ? min(count, 400) : rng.int(0...count)

				stream.u8(1)
				stream.u8(0)
				stream.u16(first)
				stream.u16(UInt16(truncatingIfNeeded: count))
				stream.append(rng.bytes(sent * 6))
			case 3, 4, 5:
				// 7.6.4: ServerCutText; a length over Int32.max is the extended form.
				let text = rng.bytes(rng.int(0...64))

				stream.u8(3)
				stream.append([0, 0, 0])

				switch rng.int(10) {
					case 0:
						let random = UInt32(truncatingIfNeeded: rng.next())

						let lengths: [UInt32] = [0x7fff_ffff, 0x8000_0000, 0xffff_ffff, 16 * 1024 * 1024 + 1, random]

						stream.u32(rng.pick(lengths))
						stream.append(text)
					case 1, 2:
						let random = UInt32(truncatingIfNeeded: rng.next())
						let allFlags: [UInt32] = [1 << 24 | 1, 1 << 24 | 0x1f, 1 << 25, 1 << 26, 1 << 27, 1 << 28 | 1, random]
						let flags = rng.pick(allFlags)
						var body = ServerStream()

						body.u32(flags)
						body.append(rng.bytes(rng.int(0...24)))

						stream.s32(-Int32(body.bytes.count))
						stream.append(body.bytes)
					default:
						stream.u32(UInt32(text.count))
						stream.append(text)
				}
			case 6:
				stream.u8(2) // 7.6.3: Bell
			case 7:
				stream.u8(150) // rfbproto.rst: EndOfContinuousUpdates
			default:
				let random = rng.byte()

				stream.u8(rng.pick([4, 5, 127, 149, 151, 248, 255, random]))
				stream.append(rng.bytes(rng.int(0...8)))
		}

		var bytes = stream.bytes

		mutate(&bytes, keepingFirst: 1)

		return bytes
	}

	// MARK: Mutation

	/// Sometimes: bytes flipped or set to edge values, the end cut off, noise added.
	private mutating func mutate(_ bytes: inout [UInt8], keepingFirst kept: Int = 0) {
		guard rng.chance(0.15), bytes.count > kept else {
			return
		}

		switch rng.int(5) {
			case 0:
				for _ in 0..<rng.int(1...4) {
					bytes[rng.int(kept...bytes.count - 1)] ^= UInt8(1 << rng.int(0...7))
				}
			case 1:
				bytes[rng.int(kept...bytes.count - 1)] = rng.pick([0, 1, 0x7f, 0x80, 0xfe, 0xff])
			case 2:
				bytes.removeLast(rng.int(1...bytes.count - kept))
			case 3:
				bytes += rng.bytes(rng.int(1...16))
			default:
				let at = rng.int(kept...bytes.count - 1)

				bytes.replaceSubrange(at..<min(bytes.count, at + 4), with: rng.bytes(4))
		}
	}
}

// MARK: - Seeds

/// The streams the regression tests send -- ConfirmedTrapTests, HostileServerTests,
/// FuzzFindingTests -- as fuzz inputs of each family, for libFuzzer to start from alongside the
/// generators'; and Apple Remote Desktop's parameters, which Tools/fuzz's "ard" family reads.
enum FuzzSeeds {
	static func regressions(for family: FuzzFamily) -> [FuzzInput] {
		func input(depth: UInt8 = 24, width: UInt16, height: UInt16, _ records: [FuzzInput.Record]) -> FuzzInput {
			.init(depth: depth, width: width, height: height, chunkLimit: .max, records: records)
		}

		func payload(_ build: (inout ServerStream) -> Void) -> [UInt8] {
			var stream = ServerStream()
			build(&stream)

			return stream.bytes
		}

		func zlibPayload(_ inflated: [UInt8]) -> [UInt8] {
			var zlib = ZlibStoredStream()
			let chunk = zlib.chunk(inflated)

			return payload { $0.u32(UInt32(chunk.count)); $0.append(chunk) }
		}

		switch family.name {
			case "raw-copyrect":
				return [
					input(width: 8, height: 8, [
						.rectangle(encoding: 0, x: 0, y: 0, width: 2, height: 2, payload: [UInt8](repeating: 0x7f, count: 16)),
						.rectangle(encoding: 1, x: 4, y: 4, width: 2, height: 2, payload: payload { $0.u16(0); $0.u16(0) })
					])
				]
			case "rre-corre":
				return [
					// ConfirmedTrapTests: a sub-rectangle at x 0xFFFF in a rectangle at x 1.
					input(width: 100, height: 100, [
						.rectangle(encoding: 2, x: 1, y: 0, width: 1, height: 1, payload: payload {
							$0.u32(1); $0.pixel(0, bytesPerPixel: 4); $0.pixel(0xffffff, bytesPerPixel: 4)
							$0.u16(0xffff); $0.u16(0); $0.u16(1); $0.u16(1)
						})
					]),
					// HostileServerTests: CoRRE at the edge of a 65535-pixel framebuffer.
					input(width: 65535, height: 1, [
						.rectangle(encoding: 4, x: 65400, y: 0, width: 135, height: 1, payload: payload {
							$0.u32(1); $0.pixel(0, bytesPerPixel: 4); $0.pixel(0xffffff, bytesPerPixel: 4)
							$0.u8(255); $0.u8(0); $0.u8(1); $0.u8(1)
						})
					])
				]
			case "hextile":
				return [
					// HostileServerTests: a 3-pixel last tile at a 65535-pixel framebuffer's edge, and
					// a subrectangle at x 15 of it.
					input(width: 65535, height: 16, [
						.rectangle(encoding: 5, x: 65500, y: 0, width: 35, height: 1, payload: payload {
							$0.u8(2); $0.pixel(0x101010, bytesPerPixel: 4); $0.u8(0)
							$0.u8(4 | 8); $0.pixel(0xf0f0f0, bytesPerPixel: 4); $0.u8(1); $0.u8(15 << 4); $0.u8(0)
						})
					])
				]
			case "zlib":
				return [
					input(width: 8, height: 8, [
						.rectangle(encoding: 6, x: 0, y: 0, width: 2, height: 2, payload: zlibPayload([UInt8](repeating: 0x40, count: 16)))
					])
				]
			case "zrle":
				return [
					// HostileServerTests: a tile ending at a 65535-pixel framebuffer's edge.
					input(width: 65535, height: 1, [
						.rectangle(encoding: 16, x: 65472, y: 0, width: 63, height: 1, payload: zlibPayload([1, 0xcc, 0xbb, 0xaa]))
					]),
					// HostileServerTests: a packed palette index of 3 in a palette of three.
					input(width: 8, height: 1, [
						.rectangle(encoding: 16, x: 0, y: 0, width: 4, height: 1,
								   payload: zlibPayload([3, 0x11, 0x11, 0x11, 0x22, 0x22, 0x22, 0x33, 0x33, 0x33, 0b00_01_10_11]))
					])
				]
			case "tight":
				return [
					input(width: 16, height: 16, [
						.rectangle(encoding: 7, x: 0, y: 0, width: 8, height: 8, payload: [0x80, 0x11, 0x22, 0x33]),
						// FuzzFindingTests: a JPEG that cannot be read.
						.rectangle(encoding: 7, x: 0, y: 0, width: 8, height: 8, payload: [0x90, 7, 0xff, 0xd8, 0xff, 0xc0, 0x00, 0x03, 0x01])
					])
				]
			case "pseudo":
				return [
					input(width: 32, height: 32, [
						.rectangle(encoding: -223, x: 0, y: 0, width: 61440, height: 4320, payload: []),
						.rectangle(encoding: -223, x: 0, y: 0, width: 65535, height: 65535, payload: [])
					]),
					input(width: 32, height: 32, [
						.rectangle(encoding: -308, x: 0, y: 0, width: 65535, height: 65535, payload: payload {
							$0.u8(1); $0.append([0, 0, 0]); $0.u32(7); $0.u16(0); $0.u16(0); $0.u16(65535); $0.u16(65535); $0.u32(0)
						}),
						.rectangle(encoding: -239, x: 1, y: 1, width: 2, height: 2, payload: [UInt8](repeating: 0xff, count: 18))
					])
				]
			case "messages":
				return [
					// ConfirmedTrapTests: one colour at entry 300, in an 8-bit session.
					input(depth: 8, width: 4, height: 4, [
						.message(payload { $0.u8(1); $0.setColourMapEntries(firstColour: 300, colours: [(0xffff, 0, 0)]) })
					]),
					// FuzzFindingTests: a ServerCutText of length 0x80000000.
					input(width: 4, height: 4, [
						.message(payload { $0.u8(3); $0.append([0, 0, 0]); $0.u32(0x8000_0000); $0.append(Array("hello".utf8)) })
					])
				]
			default:
				return []
		}
	}

	/// rfbproto.rst, Diffie-Hellman Authentication (lines 1336-1374): generator, key-size, prime,
	/// public value. RFC 2409's First and Second Oakley Groups, 768 and 1,024 bits, generator 2,
	/// each with a public value inside it; and the degenerate parameters HostileServerTests
	/// refuses: primes of one and zero, a key size of one.
	static var ard: [[UInt8]] {
		func parameters(generator: UInt16, prime: [UInt8], publicValue: [UInt8]) -> [UInt8] {
			var stream = ServerStream()
			stream.u16(generator)
			stream.u16(UInt16(prime.count))
			stream.append(prime)
			stream.append(publicValue)

			return stream.bytes
		}

		var group1Value = oakleyGroup1Prime
		group1Value[0] = 0x12
		var group2Value = oakleyGroup2Prime
		group2Value[0] = 0x12

		let zeros = [UInt8](repeating: 0, count: 127)

		return [
			parameters(generator: 2, prime: oakleyGroup1Prime, publicValue: group1Value),
			parameters(generator: 2, prime: oakleyGroup2Prime, publicValue: group2Value),
			parameters(generator: 2, prime: zeros + [1], publicValue: zeros + [2]),
			parameters(generator: 2, prime: zeros + [0], publicValue: zeros + [2]),
			parameters(generator: 2, prime: [1], publicValue: [1])
		]
	}

	/// RFC 2409 6.1, the First Oakley Default Group: 768 bits.
	static let oakleyGroup1Prime = hex("""
		FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
		29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
		EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
		E485B576 625E7EC6 F44C42E9 A63A3620 FFFFFFFF FFFFFFFF
		""")

	/// RFC 2409 6.2, the Second Oakley Group: 1,024 bits.
	static let oakleyGroup2Prime = hex("""
		FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
		29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
		EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
		E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
		EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE65381
		FFFFFFFF FFFFFFFF
		""")

	private static func hex(_ text: String) -> [UInt8] {
		let digits = Array(text.filter(\.isHexDigit))

		return stride(from: 0, to: digits.count - 1, by: 2).map {
			UInt8(String(digits[$0...$0 + 1]), radix: 16)!
		}
	}
}
