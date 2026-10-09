// A seeded, deterministic fuzz of what a server can send a client after the handshake, checking
// that the kit survives all of it: FramebufferUpdates of Raw, CopyRect, RRE, CoRRE, Hextile, zlib,
// ZRLE and Tight rectangles and of the DesktopSize, ExtendedDesktopSize, Cursor, DesktopName and
// LastRect pseudo-encodings, SetColourMapEntries, ServerCutText (and its extended form), Bell and
// EndOfContinuousUpdates, made up and mutated by ServerToClientFuzzer.swift's generators and fed
// through a ScriptedReader to the kit's own readers, the decoder table a VNCConnection builds,
// and a real VNCFramebuffer, at 8, 16 and 24 bits.
//
// Nothing here talks to a network. Every input comes from a seed, so a failure is a seed and a
// session number, and FUZZ_SEED=<seed> FUZZ_SESSIONS=<n> FUZZ_TRACE=1 replays it, printing each
// session before it runs: the last one printed is the one that trapped.
//
// Invariants:
//  no trap        a trap ends the test process; the run gets to its report only without one
//  deadline       every session finishes within `sessionDeadline` (an assertion), and a watchdog
//                 ends the process, naming the session and printing its bytes, past `hangLimit`
//  bounded memory the process's peak resident size grows by less than `memoryGrowthLimit` over
//                 the run; a framebuffer the run makes is at most FuzzSession.allocationBudget
//                 pixels (a resize to more is counted, not made: the kit's own ceiling is a
//                 gigabyte, VNCFramebuffer.maximumPixelCount)
//  errors         a session ends only where its script does or where the kit refuses a message
//                 with an error -- which the report sorts by the error's case
//
// The report says what each decoder and each message type was fed -- how many, how many bytes the
// kit read for them -- and how each ended. In the suite testFuzz runs `defaultSeeds` at
// `defaultSessionsPerSeed`. For more, in the fork's root:
//   FUZZ_SEED=31 FUZZ_SESSIONS=100000 swift test --filter ServerToClientFuzzTests
// and the same with `-c release -Xswiftc -enable-testing`, which is the build people run: some of
// what this found was compiled into debug builds only. More sessions from one seed rather than
// more seeds: FRng starts seed n one draw past seed n - 1, and two seeds' sessions fall into step
// -- seed 5's from its session 1,157 on, seed 2's from its 9,147 -- after which they repeat each
// other's. Tools/fuzz runs the same generators as seeds for libFuzzer, coverage-guided and under
// AddressSanitizer.

import XCTest
import Foundation
@testable import RoyalVNCKit

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class ServerToClientFuzzTests: XCTestCase {
	static let defaultSeeds: [UInt64] = [1, 2, 3]

#if canImport(CoreImage)
	/// Fewer where a framebuffer makes a CIContext: on an Apple-silicon Mac making one takes about
	/// 5 ms, half of what a session costs there. The Linux run, at 1,000 a seed, takes seconds.
	static let defaultSessionsPerSeed = 400
#else
	static let defaultSessionsPerSeed = 1000
#endif

	/// Most sessions take a millisecond or two; a debug build's slowest a few hundred.
	static let sessionDeadline = 5.0

	/// A session still running after this has hung.
	static let hangLimit = 60.0

	/// The most the process's peak resident size may grow over the run.
	static let memoryGrowthLimit = 512 * 1024 * 1024

	func testFuzz() async throws {
		let environment = ProcessInfo.processInfo.environment

		let seeds: [UInt64] = environment["FUZZ_SEED"].flatMap { UInt64($0) }.map { [$0] }
			?? environment["FUZZ_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) } }
			?? Self.defaultSeeds
		let sessionsPerSeed = environment["FUZZ_SESSIONS"].flatMap { Int($0) } ?? Self.defaultSessionsPerSeed
		let trace = environment["FUZZ_TRACE"] == "1"

		let tally = FuzzTally()
		let watchdog = FuzzWatchdog(limit: Self.hangLimit)
		let peakBefore = peakResidentBytes()
		let started = Date()

		var slowest = (seconds: 0.0, label: "")

		defer { watchdog.stop() }

		for seed in seeds {
			var generator = FuzzGenerator(seed: seed)

			for index in 0..<sessionsPerSeed {
				if trace {
					print("FUZZ seed \(seed) session \(index): generating")
					fflush(stdout)
				}

				let input = generator.input()
				let script = input.script
				let label = "seed \(seed) session \(index): \(input.width)x\(input.height) at \(input.depth) bits, \(script.count) bytes"

				if trace {
					print("FUZZ \(label)")
					fflush(stdout)
				}

				watchdog.begin(label, script: script)

				let sessionStarted = Date()
				let session = try FuzzSession(depth: input.depth, width: input.width, height: input.height, tally: tally)
				let outcome = await session.run(script: script, chunkLimit: input.chunkLimit)
				let elapsed = Date().timeIntervalSince(sessionStarted)

				watchdog.end()

				tally.session(outcome.hasPrefix("refused") ? "ended refused" : (outcome.hasPrefix("truncated") ? "ended truncated" : outcome))

				XCTAssertLessThan(elapsed, Self.sessionDeadline, "\(label) took \(elapsed) s")
				XCTAssertFalse(outcome.hasPrefix("other"), "\(label) ended with an error that is not the kit's: \(outcome)")

				if elapsed > slowest.seconds {
					slowest = (elapsed, label)
				}
			}
		}

		let peakAfter = peakResidentBytes()
		let elapsed = Date().timeIntervalSince(started)

		print("""
			ServerToClientFuzzTests: seeds \(seeds.map(String.init).joined(separator: ",")), \(sessionsPerSeed) sessions each, \
			\(String(format: "%.1f", elapsed)) s; slowest session \(String(format: "%.3f", slowest.seconds)) s (\(slowest.label)); \
			peak resident \(peakBefore / 1_048_576) MiB before, \(peakAfter / 1_048_576) MiB after
			\(tally.report())
			""")

		XCTAssertLessThan(peakAfter - peakBefore, Self.memoryGrowthLimit,
						  "the process's peak resident size grew by \((peakAfter - peakBefore) / 1_048_576) MiB")
		XCTAssertLessThanOrEqual(tally.largestFramebufferPixels, FuzzSession.allocationBudget)

		// Every decoder and message type was reached, and each decoded something: a generator
		// that stopped producing anything a decoder accepts would make the run look clean and
		// test nothing. LastRect, which FramebufferUpdate.receive handles itself, has no decoder
		// to count.
		for encoding: Int64 in [0, 1, 2, 4, 5, 6, 7, 16, -223, -308, -239, -307] {
			XCTAssertGreaterThan(tally.decoders[encoding]?.outcomes["decoded"] ?? 0, 0,
								 "\(FuzzTally.encodingName(encoding)) never decoded anything")
		}

		for type: UInt8 in [0, 1, 2, 3, 150] {
			XCTAssertGreaterThan(tally.messages[type]?.outcomes["decoded"] ?? 0, 0,
								 "\(FuzzTally.messageName(type)) was never decoded")
		}
	}
}

/// The process's peak resident size, in bytes.
func peakResidentBytes() -> Int {
	var usage = rusage()

#if canImport(Glibc)
	getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)

	return Int(usage.ru_maxrss) * 1024 // kilobytes on Linux
#else
	getrusage(RUSAGE_SELF, &usage)

	return Int(usage.ru_maxrss) // bytes on macOS
#endif
}

/// Ends the process, naming the session, if one runs past `limit` seconds: a hang in a decoder is
/// a loop no task can cancel, and a suite that sits there tells nobody which input did it.
final class FuzzWatchdog: @unchecked Sendable {
	private let lock = NSLock()
	private var label: String?
	private var script: [UInt8] = []
	private var started = Date()
	private var stopped = false

	init(limit: Double) {
		let thread = Thread { [weak self] in
			while true {
				Thread.sleep(forTimeInterval: 0.25)

				guard let self else {
					return
				}

				self.lock.lock()

				if self.stopped {
					self.lock.unlock()

					return
				}

				if let label = self.label, Date().timeIntervalSince(self.started) > limit {
					let hex = self.script.prefix(4096).map { String(format: "%02x", $0) }.joined()

					print("FUZZ HANG: \(label) has run for more than \(limit) s. Its script (first 4 KiB): \(hex)")
					fflush(stdout)
					abort()
				}

				self.lock.unlock()
			}
		}

		thread.start()
	}

	func begin(_ label: String, script: [UInt8]) {
		lock.lock()
		self.label = label
		self.script = script
		started = Date()
		lock.unlock()
	}

	func end() {
		lock.lock()
		label = nil
		lock.unlock()
	}

	func stop() {
		lock.lock()
		stopped = true
		lock.unlock()
	}
}
