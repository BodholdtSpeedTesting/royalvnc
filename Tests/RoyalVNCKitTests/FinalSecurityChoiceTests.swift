// VNCConnection.securityTypeChooserIsFinal: an embedder's chooser whose answer is the only one, against a
// scripted server (ScriptedTransport): nothing is dialled. RFB 3.8's list of security types and RFB 3.3's single
// stated type (RFC 6143 7.1.2): with the flag, a chooser that declines ends the connection before anything after
// the client's ProtocolVersion is written; without it, the built-in order and the 3.3 server's choice stand.

import XCTest
@testable import RoyalVNCKit

final class FinalSecurityChoiceTests: XCTestCase {
	/// RFB 3.3: the server states None (type 1, a U32), then -- 3.3 has no SecurityResult after None -- its
	/// ServerInit, as ScriptedServer.serverInit has it after its 3.8 security exchange.
	private var script33: [UInt8] {
		Array("RFB 003.003\n".utf8) + [ 0, 0, 0, 1 ]
			+ ScriptedServer.serverInit(width: 4, height: 4).dropFirst(12 + 2 + 4)
	}

	/// RFB 3.8, offering None alone.
	private var script38: [UInt8] {
		ScriptedServer.serverInit(width: 4, height: 4)
	}

	private struct Run {
		let outcome: String
		let written: Int
		let asked: [[VNCSecurityMethod]]
	}

	private final class Asked: @unchecked Sendable {
		private let lock = NSLock()
		private var lists: [[VNCSecurityMethod]] = []

		func note(_ offered: [VNCSecurityMethod]) {
			lock.lock(); lists.append(offered); lock.unlock()
		}

		var all: [[VNCSecurityMethod]] {
			lock.lock(); defer { lock.unlock() }

			return lists
		}
	}

	private func run(_ script: [UInt8], isFinal: Bool,
					 answer: VNCSecurityMethod?) async -> Run {
		let transport = ScriptedTransport(script: script)
		let watcher = ConnectionOutcome()
		let asked = Asked()
		let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
											  hostname: "scripted.invalid",
											  port: 5900,
											  isShared: true,
											  isScalingEnabled: false,
											  useDisplayLink: false,
											  inputMode: .none,
											  isClipboardRedirectionEnabled: false,
											  colorDepth: .depth24Bit,
											  frameEncodings: [.raw])
		let connection = VNCConnection(settings: settings,
									   logger: QuietLogger(),
									   framebufferAllocator: CappedAllocator(limit: 64 * 1024 * 1024),
									   context: nil)

		connection.transportProvider = { _, _ in transport }
		connection.securityTypeChooser = { offered in
			asked.note(offered)

			return answer
		}
		connection.securityTypeChooserIsFinal = isFinal
		connection.delegate = watcher
		connection.connect()

		let outcome = await watcher.outcome(within: 10)
		let written = transport.writtenByteCount

		connection.disconnect()

		return Run(outcome: "\(outcome)", written: written, asked: asked.all)
	}

	private func assertDeclinedBeforeAnythingWasSent(_ run: Run, file: StaticString = #filePath, line: UInt = #line) {
		XCTAssertTrue(run.outcome.hasPrefix("disconnected"), "connected anyway: \(run.outcome)", file: file, line: line)
		XCTAssertTrue(run.outcome.contains("\(VNCError.authentication(.clientCouldNotDecideOnSecurityType))")
						|| run.outcome.localizedCaseInsensitiveContains("security type"),
					  "ended for another reason: \(run.outcome)", file: file, line: line)

		// The client's 12-byte ProtocolVersion and nothing after it: no security type (3.8), no ClientInit.
		XCTAssertEqual(run.written, 12, "bytes the client wrote", file: file, line: line)
	}

	// MARK: - RFB 3.8

	func testAFinalChooserThatDeclinesEndsThe38Handshake() async {
		let run = await run(script38, isFinal: true, answer: nil)

		XCTAssertEqual(run.asked, [ [ .noAuthentication ] ])
		assertDeclinedBeforeAnythingWasSent(run)
	}

	func testAFinalChooserAnsweringATypeNotOfferedEndsThe38Handshake() async {
		let run = await run(script38, isFinal: true, answer: .veNCrypt)

		assertDeclinedBeforeAnythingWasSent(run)
	}

	func testAFinalChooserThatChoosesConnects() async {
		let run = await run(script38, isFinal: true, answer: .noAuthentication)

		XCTAssertEqual(run.outcome, "a 4x4 framebuffer")
	}

	func testWithoutTheFlagADecliningChooserFallsBackToTheBuiltInOrder() async {
		let run = await run(script38, isFinal: false, answer: nil)

		XCTAssertEqual(run.outcome, "a 4x4 framebuffer")
	}

	// MARK: - RFB 3.3

	func testAFinalChooserIsAskedAboutTheType33StatesAndCanDecline() async {
		let run = await run(script33, isFinal: true, answer: nil)

		XCTAssertEqual(run.asked, [ [ .noAuthentication ] ], "asked about the one type the server stated")
		assertDeclinedBeforeAnythingWasSent(run)
	}

	func testAFinalChooserThatAcceptsThe33TypeConnects() async {
		let run = await run(script33, isFinal: true, answer: .noAuthentication)

		XCTAssertEqual(run.outcome, "a 4x4 framebuffer")
	}

	func testWithoutTheFlag33IsNotAsked() async {
		let run = await run(script33, isFinal: false, answer: nil)

		XCTAssertEqual(run.outcome, "a 4x4 framebuffer")
		XCTAssertEqual(run.asked, [], "the 3.3 server's type is used as it always was")
	}
}
