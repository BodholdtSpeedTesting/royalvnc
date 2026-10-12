// What `BufferedTransport` asks of the transport under it, and what it keeps from it, read by
// read: the block it asks for, a large read passed straight through, and nothing read ahead
// served once the transport has been cancelled.

import Foundation
import XCTest
@testable import RoyalVNCKit

final class BufferedTransportTests: XCTestCase {
	/// Small reads take one read of the transport between them, a block of up to 64 KiB asked for
	/// with a minimum of one byte, and are served from it in order.
	func testSmallReadsAreServedFromOneBlock() async throws {
		let script = (0..<1_000).map { UInt8($0 % 251) }
		let base = RecordingTransport(script: script)
		let buffered = BufferedTransport(base)

		var read = [UInt8]()

		for length in [1, 2, 4, 12, 3] {
			let data = try await buffered.readTransport(minimumLength: length, maximumLength: length)

			XCTAssertEqual(data.count, length)
			read += data
		}

		XCTAssertEqual(read, Array(script.prefix(22)))
		XCTAssertEqual(base.asked.map(\.minimum), [1])
		XCTAssertEqual(base.asked.map(\.maximum), [64 * 1024])
	}

	/// A read of a block or more, with nothing waiting, is the transport's own read: asked for with
	/// the read's maximum and handed back as it came, rather than copied through the buffer in
	/// blocks.
	func testAReadOfABlockOrMoreGoesStraightThrough() async throws {
		let length = 200 * 1024
		let script = (0..<length).map { UInt8($0 % 251) }
		let base = RecordingTransport(script: script)
		let buffered = BufferedTransport(base)

		let data = try await buffered.readTransport(minimumLength: 1, maximumLength: length)

		XCTAssertEqual(data, Data(script))
		XCTAssertEqual(base.asked.map(\.maximum), [length])
	}

	/// A read whose minimum is more than one block reads blocks until it has its minimum, then
	/// takes up to its maximum, the rest kept for the reads after it.
	func testAReadLongerThanABlockGathersBlocks() async throws {
		let script = (0..<300_000).map { UInt8($0 % 251) }
		let base = RecordingTransport(script: script, servingAtMost: 50_000)
		let buffered = BufferedTransport(base)

		let data = try await buffered.readTransport(minimumLength: 120_000, maximumLength: 120_000)
		let next = try await buffered.readTransport(minimumLength: 10, maximumLength: 10)

		XCTAssertEqual(data, Data(script.prefix(120_000)))
		XCTAssertEqual(next, Data(script[120_000..<120_010]))
	}

	/// Once the transport is cancelled, what was read ahead is not handed out: the next read goes to
	/// the transport, which fails as a cancelled transport does. The kit looks for a disconnect only
	/// between messages, so its decoders read on after a cancel until a read fails; served from a
	/// block, they would go on drawing for up to 64 KiB after the connection was ended.
	func testWhatWasReadAheadIsDroppedWhenTheTransportIsCancelled() async throws {
		let base = RecordingTransport(script: (0..<100).map { UInt8($0) })
		let buffered = BufferedTransport(base)

		_ = try await buffered.readTransport(minimumLength: 1, maximumLength: 1)
		_ = try await buffered.readTransport(minimumLength: 1, maximumLength: 1)

		// The precondition: 98 bytes are waiting, read ahead by the first read alone. Otherwise the
		// read below would fail for want of bytes, cancelled or not.
		XCTAssertEqual(base.asked.count, 1)

		buffered.cancelTransport()

		do {
			let data = try await buffered.readTransport(minimumLength: 1, maximumLength: 1)

			XCTFail("a read after the cancel was handed \(Array(data)), read ahead before it")
		} catch {
			XCTAssertEqual(base.asked.count, 2, "the read after the cancel did not go to the transport")
		}
	}

	/// A transport that hands back no bytes for a read with a minimum of one has broken its
	/// contract; asking it again would spin, so the read fails.
	func testATransportThatHandsBackNothingFailsTheRead() async throws {
		let buffered = BufferedTransport(EmptyHandedTransport())

		do {
			_ = try await buffered.readTransport(minimumLength: 1, maximumLength: 4)

			XCTFail("a read was answered from a transport that returned nothing")
		} catch let error as VNCError {
			guard case .protocol(.invalidData) = error else {
				return XCTFail("the read failed with \(error)")
			}
		}
	}
}

/// A transport whose peer is a script, recording what each read of it asked for.
private final class RecordingTransport: VNCTransport, @unchecked Sendable {
	struct Asked {
		let minimum: Int
		let maximum: Int
	}

	private let lock = NSLock()
	private let script: [UInt8]
	private let servingAtMost: Int
	private var offset = 0
	private var cancelled = false
	private var reads = [Asked]()

	init(script: [UInt8], servingAtMost: Int = .max) {
		self.script = script
		self.servingAtMost = servingAtMost
	}

	var asked: [Asked] {
		lock.lock()
		defer { lock.unlock() }

		return reads
	}

	var isTransportReady: Bool { true }
	var transportState: VNCTransportState { .ready }

	func setTransportStateHandler(_ handler: VNCTransportStateHandler?) { }
	func startTransport(queue: DispatchQueue) { }

	func cancelTransport() {
		lock.lock()
		cancelled = true
		lock.unlock()
	}

	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data {
		lock.lock()
		defer { lock.unlock() }

		reads.append(Asked(minimum: minimumLength, maximum: maximumLength))

		guard !cancelled, script.count - offset >= max(1, minimumLength) else {
			throw VNCError.connection(.closed)
		}

		let count = min(maximumLength, servingAtMost, script.count - offset)
		let chunk = Data(script[offset..<offset + count])

		offset += count

		return chunk
	}

	func writeTransport(data: Data) async throws { }
}

/// A transport that answers every read with no bytes.
private final class EmptyHandedTransport: VNCTransport, @unchecked Sendable {
	var isTransportReady: Bool { true }
	var transportState: VNCTransportState { .ready }

	func setTransportStateHandler(_ handler: VNCTransportStateHandler?) { }
	func startTransport(queue: DispatchQueue) { }
	func cancelTransport() { }

	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data {
		Data()
	}

	func writeTransport(data: Data) async throws { }
}
