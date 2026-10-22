// The protocol version a server announced (VNCConnection.serverProtocolVersion), as the kit's own
// handshake reads it from the server's ProtocolVersion message (RFC 6143 7.1.1) -- RFB 3.8's, 3.7's,
// and the 003.889 Apple's Screen Sharing announces -- against a scripted server (ScriptedTransport):
// nothing is dialled.

import XCTest
@testable import RoyalVNCKit

final class ServerProtocolVersionTests: XCTestCase {
	/// The script of ScriptedServer.serverInit -- one security type, None, SecurityResult OK and a
	/// ServerInit -- after the server's ProtocolVersion `version`, the 12 bytes "RFB xxx.yyy\n".
	private func script(announcing version: String) -> [UInt8] {
		Array(version.utf8) + ScriptedServer.serverInit(width: 4, height: 4).dropFirst(12)
	}

	/// Runs a connection against `script` until a framebuffer or a disconnection settles it, and gives the
	/// connection back, disconnected.
	private func connected(to script: [UInt8]) async -> (connection: VNCConnection, outcome: ConnectionOutcome.Outcome) {
		let transport = ScriptedTransport(script: script)
		let watcher = ConnectionOutcome()
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
		connection.delegate = watcher
		connection.connect()

		let outcome = await watcher.outcome(within: 10)

		connection.disconnect()

		return (connection, outcome)
	}

	private func numbers(_ version: (major: UInt32, minor: UInt32)?) -> [UInt32]? {
		version.map { [ $0.major, $0.minor ] }
	}

	func testNothingIsKnownBeforeTheServerSpeaks() {
		let settings = VNCConnection.Settings(isDebugLoggingEnabled: false, hostname: "scripted.invalid", port: 5900,
											  isShared: true, isScalingEnabled: false, useDisplayLink: false,
											  inputMode: .none, isClipboardRedirectionEnabled: false,
											  colorDepth: .depth24Bit, frameEncodings: [.raw])

		XCTAssertNil(VNCConnection(settings: settings, logger: QuietLogger()).serverProtocolVersion)
	}

	func testTheVersionTheServerAnnouncedIsKept() async {
		let (connection, outcome) = await connected(to: ScriptedServer.serverInit(width: 4, height: 4))

		XCTAssertEqual("\(outcome)", "a 4x4 framebuffer")
		XCTAssertEqual(numbers(connection.serverProtocolVersion), [ 3, 8 ])
	}

	func testApplesScreenSharingsVersionIsKeptAsAnnounced() async {
		// RFB 003.889, which the kit answers as 3.8 and handshakes as 3.8 (a list of security types).
		let (connection, outcome) = await connected(to: script(announcing: "RFB 003.889\n"))

		XCTAssertEqual("\(outcome)", "a 4x4 framebuffer")
		XCTAssertEqual(numbers(connection.serverProtocolVersion), [ 3, 889 ])
		XCTAssertTrue(connection.state.isAppleRemoteDesktop, "what the kit itself decides by")
	}

	func testA37ServersVersionIsKept() async {
		// RFB 3.7: the same list of security types, and no SecurityResult after None (rfbproto.rst, None: "Version 3.3
		// and 3.7: The protocol passes to the initialisation phase").
		var script = Array("RFB 003.007\n".utf8) + [ 1, 1 ]
		script += ScriptedServer.serverInit(width: 4, height: 4).dropFirst(12 + 2 + 4)
		let (connection, outcome) = await connected(to: script)

		XCTAssertEqual("\(outcome)", "a 4x4 framebuffer")
		XCTAssertEqual(numbers(connection.serverProtocolVersion), [ 3, 7 ])
	}
}
