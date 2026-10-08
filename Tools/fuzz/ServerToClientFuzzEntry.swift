// libFuzzer's entry points for what a server sends a client: README.md says how to build and run
// them. Compiled with Tests/RoyalVNCKitTests/ScriptedReader.swift and ServerToClientFuzzer.swift,
// whose session, generators and seeds the seeded fuzz in the suite runs too.
//
// FUZZ_FAMILY picks what a run spends its time on: one of FuzzFamily.all's names, each a set of
// encodings its rectangles keep to (raw-copyrect, rre-corre, hextile, zlib, zrle, tight, pseudo)
// or every encoding with other messages between them (messages); or "ard", Apple Remote
// Desktop's Diffie-Hellman parameters. FUZZ_WRITE_SEEDS=<directory> writes the family's seeds
// there -- the generators' inputs and the regression tests' streams -- and exits.

import Foundation

#if canImport(Glibc)
import Glibc
#endif

import Dispatch
@testable import RoyalVNCKit

private var family = FuzzFamily.named("messages")!
private var isARD = false

/// What every input was fed and how it ended, for the report at exit.
private let tally = FuzzTally()
private var ardOutcomes = [String: Int]()

@_cdecl("LLVMFuzzerInitialize")
public func fuzzerInitialize(_ argc: UnsafeMutableRawPointer?, _ argv: UnsafeMutableRawPointer?) -> Int32 {
	let environment = ProcessInfo.processInfo.environment
	let name = environment["FUZZ_FAMILY"] ?? "messages"

	if name == "ard" {
		isARD = true
	} else if let named = FuzzFamily.named(name) {
		family = named
	} else {
		print("FUZZ_FAMILY \(name) is none of: \(FuzzFamily.all.map(\.name).joined(separator: ", ")), ard")
		exit(2)
	}

	if let directory = environment["FUZZ_WRITE_SEEDS"] {
		writeSeeds(to: directory, family: name)
		exit(0)
	}

	atexit {
		print("server-to-client-fuzz: \(isARD ? "ard" : family.name)")

		if isARD {
			print(ardOutcomes.sorted { $0.value > $1.value }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n"))
		} else {
			print(tally.report())
		}
	}

	return 0
}

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzerTestOneInput(_ data: UnsafePointer<UInt8>?, _ size: Int) -> Int32 {
	let bytes = data.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
	let done = DispatchSemaphore(value: 0)

	// The decoders are async; libFuzzer's thread waits for them, as nothing else runs here.
	Task {
		if isARD {
			await runARD(bytes)
		} else {
			await runSession(bytes)
		}

		done.signal()
	}

	done.wait()

	return 0
}

private func runSession(_ bytes: [UInt8]) async {
	let input = FuzzInput(fuzzBytes: bytes, family: family)

	guard let session = try? FuzzSession(depth: input.depth, width: input.width, height: input.height, tally: tally) else {
		return
	}

	let outcome = await session.run(script: input.script, chunkLimit: input.chunkLimit)

	tally.session(outcome.hasPrefix("refused") ? "ended refused" : (outcome.hasPrefix("truncated") ? "ended truncated" : outcome))
}

/// The parameters as the server sends them, read and checked as the kit does; a group it accepts
/// of up to 96 bytes is then used, as the kit would, to make keys and encrypt credentials.
private func runARD(_ bytes: [UInt8]) async {
	do {
		let auth = try await VNCProtocol.ARDAuthentication.receive(connection: ScriptedReader(bytes))

		ardOutcomes["accepted", default: 0] += 1

		guard auth.keySize <= 96 else {
			return
		}

		guard let agreement = VNCProtocol.ARDAuthentication.DiffieHellmanKeyAgreement(prime: auth.prime,
																					  generator: auth.generator,
																					  peerKey: auth.peerKey,
																					  keyLength: Int(auth.keySize)) else {
			ardOutcomes["no agreement", default: 0] += 1

			return
		}

		let authentication = VNCProtocol.ARDAuthentication.Authentication(agreement: agreement,
																		  username: "user",
																		  password: "password")

		ardOutcomes[authentication == nil ? "agreed, not encrypted" : "agreed and encrypted", default: 0] += 1
	} catch {
		ardOutcomes[FuzzTally.outcome(of: error), default: 0] += 1
	}
}

private func writeSeeds(to directory: String, family name: String) {
	let base = URL(fileURLWithPath: directory)

	try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

	var seeds = [[UInt8]]()

	if name == "ard" {
		seeds = FuzzSeeds.ard
	} else if let family = FuzzFamily.named(name) {
		seeds = FuzzSeeds.regressions(for: family).map { $0.fuzzBytes(family: family) }

		for seed in 1...300 {
			var generator = FuzzGenerator(seed: UInt64(seed))

			seeds.append(generator.input(family: family).fuzzBytes(family: family))
		}
	}

	for (index, seed) in seeds.enumerated() {
		try? Data(seed).write(to: base.appendingPathComponent(String(format: "seed-%04d", index)))
	}

	print("wrote \(seeds.count) seeds for \(name) to \(directory)")
}
