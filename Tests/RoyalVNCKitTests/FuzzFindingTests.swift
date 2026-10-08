// What the fuzzing of server-to-client messages found -- the seeded fuzz in ServerToClientFuzzTests
// and the libFuzzer runs in Tools/fuzz -- each the smallest stream that shows it, kept as a test.

import XCTest
@testable import RoyalVNCKit

final class FuzzFindingTests: XCTestCase {
	// MARK: - ServerCutText (RFC 6143 7.6.4; rfbproto.rst's extended form)

	private func receiveCutText(_ stream: ServerStream) async throws -> (VNCProtocol.ServerCutText, remaining: Int) {
		let reader = ScriptedReader(stream.bytes)
		let cutText = try await VNCProtocol.ServerCutText.receive(connection: reader, logger: QuietLogger())

		return (cutText, reader.remaining)
	}

	/// A length of 0x80000000 is Int32.min read as signed, which the kit takes for the extended
	/// form, and `Int32(abs(length))` -- one past Int32.max -- trapped. Found by the seeded fuzz,
	/// seed 1, session 53.
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
