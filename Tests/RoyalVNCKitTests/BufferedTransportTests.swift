// What `BufferedTransport` asks of the transport under it, and what it keeps from it, read by
// read: the block it asks for, a large read passed straight through, and, once the transport has
// been cancelled, nothing served that was read ahead or that the transport answered after it.

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

	/// A read of the transport already in flight when it is cancelled can still be answered -- an
	/// NWConnection completion already on its way, a `recv` that had returned -- and nothing that
	/// answer brings is served: not to the read in flight, nor to any read made after the cancel.
	/// At 1d50ace the cancel emptied the buffer and the answer refilled it: the read in flight was
	/// handed a byte of it, and 65,535 one-byte reads made after the cancel the rest.
	func testABlockThatComesBackAfterTheCancelIsNotServed() async throws {
		let base = AnsweredAtCancelTransport(answer: Data(repeating: 0xab, count: 64 * 1024))
		let buffered = BufferedTransport(base)

		let inFlight = Task { try await buffered.readTransport(minimumLength: 1, maximumLength: 1) }

		while base.askedCount == 0 {
			try await Task.sleep(nanoseconds: 1_000_000)
		}

		buffered.cancelTransport()

		if case .success(let data) = await inFlight.result {
			XCTFail("the read in flight at the cancel was handed \(Array(data)), from an answer that came after it")
		}

		var servedAfterTheCancel = 0

		// Bounded: past a block, nothing more could have come from the answer.
		while servedAfterTheCancel <= 70_000 {
			do {
				_ = try await buffered.readTransport(minimumLength: 1, maximumLength: 1)

				servedAfterTheCancel += 1
			} catch {
				break
			}
		}

		XCTAssertEqual(servedAfterTheCancel, 0,
					   "\(servedAfterTheCancel) one-byte reads made after the cancel were served from an answer that came after it")
	}

	/// The same for a read of a block or more, which is handed straight back rather than kept: an
	/// answer that came after the cancel is not handed to it. At 1d50ace it was, all 200 KiB.
	func testAReadPassedStraightThroughIsNotHandedAnAnswerThatCameAfterTheCancel() async throws {
		let length = 200 * 1024
		let base = AnsweredAtCancelTransport(answer: Data(repeating: 0xab, count: length))
		let buffered = BufferedTransport(base)

		let inFlight = Task { try await buffered.readTransport(minimumLength: 1, maximumLength: length) }

		while base.askedCount == 0 {
			try await Task.sleep(nanoseconds: 1_000_000)
		}

		// The precondition: the read went straight through, asking for its own maximum.
		XCTAssertEqual(base.askedMaximum, length)

		buffered.cancelTransport()

		switch await inFlight.result {
		case .success(let data):
			XCTFail("the read in flight at the cancel was handed \(data.count) bytes that came after it")
		case .failure(let error):
			guard case .connection(.cancelled) = error as? VNCError else {
				return XCTFail("the read in flight failed with \(error), not as cancelled")
			}
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

/// A transport whose first read is answered only when it is cancelled, with `answer`: the answer
/// already on its way when the cancel came. Every other read fails, as a closed transport's does.
private final class AnsweredAtCancelTransport: VNCTransport, @unchecked Sendable {
	private let lock = NSLock()
	private let answer: Data
	private var cancelled = false
	private var asked = [Int]()
	private var waiting: CheckedContinuation<Data, Error>?

	init(answer: Data) {
		self.answer = answer
	}

	/// How many reads have been made of this transport.
	var askedCount: Int {
		lock.lock()
		defer { lock.unlock() }

		return asked.count
	}

	/// The maximum the first read asked for.
	var askedMaximum: Int? {
		lock.lock()
		defer { lock.unlock() }

		return asked.first
	}

	var isTransportReady: Bool { true }
	var transportState: VNCTransportState { .ready }

	func setTransportStateHandler(_ handler: VNCTransportStateHandler?) { }
	func startTransport(queue: DispatchQueue) { }

	func cancelTransport() {
		lock.lock()
		cancelled = true
		let pending = waiting
		waiting = nil
		lock.unlock()

		pending?.resume(returning: answer)
	}

	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			lock.lock()
			asked.append(maximumLength)

			if !cancelled, asked.count == 1 {
				waiting = continuation
				lock.unlock()

				return
			}

			lock.unlock()
			continuation.resume(throwing: VNCError.connection(.closed))
		}
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
