// The last bytes of a stream, when Network.framework reports them in the same completion as the
// stream's end, are read, and the end is reported by the read after them.
//
// A server refusing a client before any security type -- RFC 6143 7.1.2: zero security types, then
// "a string describing the reason" -- closes the connection straight after it: "The server closes
// the connection after sending the reason-string." Network.framework can hand a receive the reason
// and the close together: content, with isComplete set. The kit's read threw `.closed` for any
// completion with isComplete before looking at its content, so the reason went with it and the
// handshake's `try?` made it nil: "The Server offered no authentication types." and nothing more,
// in 2-7 of 10 connections over a LAN. Apple's header for the receive completion
// (Network.framework's connection.h, nw_connection_receive_completion_t) says the caller "should
// process all content it receives".
//
// Each test plays the server on a loopback socket of its own, sends what it sends and its FIN (one
// test a reset in its place), and lets both arrive before the client reads.

#if canImport(Network)
import Foundation
import Network
import XCTest
@testable import RoyalVNCKit

final class NWConnectionEndTests: XCTestCase {
	/// RFC 6143 7.1.2's reason-length and reason-string.
	private static let reason = "This desktop is a session the server cannot share. Someone at the computer can log out "
		+ "and back in with one it can, and it then shares automatically."

	private static var reasonBytes: [UInt8] {
		var stream = ServerStream()
		stream.u32(UInt32(reason.utf8.count))
		stream.append(Array(reason.utf8))

		return stream.bytes
	}

	/// A read that asks for more than the peer sent, made once the bytes and the FIN are both in, is
	/// handed the bytes; the read after it reports the close as `.closed`, and so does the one after
	/// that. At d360fe0 the first read threw `.closed` and the bytes were lost.
	///
	/// Asking for more than is there is what a read of a block does, and on loopback it is what has
	/// Network.framework report the end with the content. A receive of exactly what remains gets the
	/// content alone and the end on its own next time, which is why a kit reading a field at a time saw
	/// this only over a network, and only sometimes. The first connection below witnesses that this
	/// setup does produce such a completion, so the test cannot pass by never meeting one.
	func testBytesThatArriveWithTheCloseAreReadAndTheCloseIsTheNextRead() async throws {
		let sent = Self.reasonBytes

		let witness = try await LoopbackPeer.connected()
		witness.peer.send(sent, thenClose: true)

		try await Task.sleep(nanoseconds: 100_000_000)

		let completion = await witness.connection.receiveOnce(maximumLength: 64 * 1024)

		witness.connection.cancel()

		XCTAssertEqual(completion.count, sent.count, "the witness's receive brought \(completion)")
		XCTAssertTrue(completion.isComplete,
					  "this setup no longer brings the content and the end together (\(completion)); the test needs another way to")

		let (peer, connection) = try await LoopbackPeer.connected()
		let transport = NWConnectionTransport(connection)

		defer { transport.cancelTransport() }

		peer.send(sent, thenClose: true)

		try await Task.sleep(nanoseconds: 100_000_000)

		let read = try await transport.readTransport(minimumLength: 1, maximumLength: 64 * 1024)

		XCTAssertEqual(read, Data(sent))

		for attempt in ["the next read", "the read after it"] {
			do {
				let more = try await transport.readTransport(minimumLength: 1, maximumLength: 64 * 1024)

				XCTFail("\(attempt) was handed \(more.count) bytes after the close")
			} catch let error as VNCError {
				guard case .connection(.closed) = error else {
					XCTFail("\(attempt) failed with \(error), not as a closed connection")
					continue
				}
			} catch {
				// Network.framework's own answer to a receive after the end is POSIX 96, ENODATA, "No
				// message available on STREAM": the close is the kit's to remember.
				XCTFail("\(attempt) failed with \(error), not as a closed connection")
			}
		}
	}

	/// The same rule for a reset: the bytes that arrive with it are read, and the reset is the next
	/// read's to report, and the one's after it. A server that closes with what the client sent
	/// still unread ends the connection with a reset rather than a FIN, and Network.framework
	/// hands a receive made once both are in the bytes and the error in one completion -- the
	/// case connection.h's note on the receive completion's content is about: "the content may be
	/// non-NULL even in the case of an error". The first connection below witnesses that this setup
	/// does produce such a completion. d360fe0 threw the error before it looked at the content, and
	/// so did 1d50ace's read with the error put first again, which every other test passed.
	func testBytesThatArriveWithAResetAreReadAndTheResetIsTheNextRead() async throws {
		let sent = Self.reasonBytes

		let witness = try await LoopbackPeer.connected()
		witness.peer.sendThenReset(sent)

		try await Task.sleep(nanoseconds: 100_000_000)

		let completion = await witness.connection.receiveOnce(maximumLength: 64 * 1024)

		witness.connection.cancel()

		XCTAssertEqual(completion.count, sent.count, "the witness's receive brought \(completion)")
		XCTAssertNotNil(completion.error,
						"this setup no longer brings the content and the reset together (\(completion)); the test needs another way to")

		let (peer, connection) = try await LoopbackPeer.connected()
		let transport = NWConnectionTransport(connection)

		defer { transport.cancelTransport() }

		peer.sendThenReset(sent)

		try await Task.sleep(nanoseconds: 100_000_000)

		do {
			let read = try await transport.readTransport(minimumLength: 1, maximumLength: 64 * 1024)

			XCTAssertEqual(read, Data(sent))
		} catch {
			return XCTFail("the first read failed with \(error): the \(sent.count) bytes before the reset were lost")
		}

		for attempt in ["the next read", "the read after it"] {
			do {
				let more = try await transport.readTransport(minimumLength: 1, maximumLength: 64 * 1024)

				XCTFail("\(attempt) was handed \(more.count) bytes after the reset")
			} catch let error as NWError {
				guard case .posix(.ECONNRESET) = error else {
					XCTFail("\(attempt) failed with \(error), not as the reset")
					continue
				}
			} catch {
				XCTFail("\(attempt) failed with \(error), not as the reset")
			}
		}
	}

	/// A whole connection, over a transport adopted ready, whose server has already sent 3.8's
	/// refusal -- zero security types and the reason (RFC 6143 7.1.2) -- and closed. The kit reads
	/// the server's version in a block that takes the rest and the end with it, and the reason reaches
	/// the error the embedder is handed. (At d360fe0, reading a field at a time, a receive of exactly
	/// what remained never met the end on loopback; with blocks and d360fe0's rule for the end, this
	/// fails in the version read.)
	func testAThreeEightRefusalThatArrivesWithTheCloseKeepsItsReason() async throws {
		var stream = ServerStream()
		stream.append(Array("RFB 003.008\n".utf8))
		stream.u8(0)    // number-of-security-types
		stream.append(Self.reasonBytes)

		try await assertRefusalKeepsItsReason(stream.bytes)
	}

	/// The same for 3.3, whose server states a single security type: 0, then the reason (Appendix
	/// A.1). One test each, so that each failure is reported: XCTest can drop a second failure that
	/// arrives while it is still recording the first.
	func testAThreeThreeRefusalThatArrivesWithTheCloseKeepsItsReason() async throws {
		var stream = ServerStream()
		stream.append(Array("RFB 003.003\n".utf8))
		stream.u32(0)   // security-type, 3.3's single U32
		stream.append(Self.reasonBytes)

		try await assertRefusalKeepsItsReason(stream.bytes)
	}

	private func assertRefusalKeepsItsReason(_ refusal: [UInt8],
											 file: StaticString = #filePath,
											 line: UInt = #line) async throws {
		let (peer, connection) = try await LoopbackPeer.connected()

		peer.send(refusal, thenClose: true)

		try await Task.sleep(nanoseconds: 100_000_000)

		let transport = NWConnectionTransport(connection)
		let ending = Ending()

		let client = VNCConnection(settings: Self.settings,
								   logger: QuietLogger(),
								   framebufferAllocator: CappedAllocator(limit: 64 * 1024 * 1024),
								   context: nil)

		client.transportProvider = { _, _ in transport }
		client.delegate = ending
		client.connect()

		let error = await ending.error(within: 10)

		client.disconnect()

		withExtendedLifetime(peer) { }

		guard let vncError = error as? VNCError,
			  case .authentication(.serverOfferedNoAuthTypes(let reason)) = vncError else {
			return XCTFail("the connection ended with \(error.map { "\($0)" } ?? "nothing")", file: file, line: line)
		}

		XCTAssertEqual(reason, Self.reason, file: file, line: line)
	}

	private static let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
														 hostname: "127.0.0.1",
														 port: 5900,
														 isShared: true,
														 isScalingEnabled: false,
														 useDisplayLink: false,
														 inputMode: .none,
														 isClipboardRedirectionEnabled: false,
														 colorDepth: .depth24Bit,
														 frameEncodings: [.raw])
}

/// The error a connection ended with.
private final class Ending: VNCConnectionDelegate, @unchecked Sendable {
	private let lock = NSLock()
	private var ended = false
	private var ending: Error?

	/// Polls rather than waits, so that no thread of the test's own is held.
	func error(within seconds: Double) async -> Error? {
		let deadline = Date().addingTimeInterval(seconds)

		while Date() < deadline {
			let (done, error) = current

			if done {
				return error
			}

			try? await Task.sleep(nanoseconds: 20_000_000)
		}

		return current.error
	}

	private var current: (done: Bool, error: Error?) {
		lock.lock()
		defer { lock.unlock() }

		return (ended, ending)
	}

	func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
		guard connectionState.status == .disconnected else {
			return
		}

		lock.lock()

		if !ended {
			ended = true
			ending = connectionState.error
		}

		lock.unlock()
	}

	func connection(_ connection: VNCConnection,
					credentialFor authenticationType: VNCAuthenticationType,
					completion: @escaping (VNCCredential?) -> Void) {
		completion(nil)
	}

	func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) { }
	func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) { }

	func connection(_ connection: VNCConnection,
					didUpdateFramebuffer framebuffer: VNCFramebuffer,
					x: UInt16, y: UInt16, width: UInt16, height: UInt16) { }

	func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) { }
}

/// The server's end of a loopback TCP connection: a listener on 127.0.0.1, the one connection it
/// accepts, and what it sends on it.
private final class LoopbackPeer: @unchecked Sendable {
	private let listener: Int32
	private var accepted: Int32 = -1

	let port: UInt16

	private init() throws {
		let fd = socket(AF_INET, SOCK_STREAM, 0)

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = 0
		address.sin_addr.s_addr = inet_addr("127.0.0.1")

		let bound = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}

		var assigned = sockaddr_in()
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)

		let named = withUnsafeMutablePointer(to: &assigned) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(fd, $0, &length)
			}
		}

		guard fd >= 0, bound == 0, listen(fd, 1) == 0, named == 0 else {
			let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)

			close(fd)

			throw failure
		}

		listener = fd
		port = UInt16(bigEndian: assigned.sin_port)
	}

	deinit {
		if accepted >= 0 {
			close(accepted)
		}

		close(listener)
	}

	/// A peer, and a ready NWConnection to it whose connection the peer has accepted.
	static func connected() async throws -> (peer: LoopbackPeer, connection: NWConnection) {
		let peer = try LoopbackPeer()
		let connection = NWConnection(host: "127.0.0.1",
									  port: NWEndpoint.Port(rawValue: peer.port)!,
									  using: .tcp)

		connection.start(queue: DispatchQueue(label: "NWConnectionEndTests"))

		// The listener's backlog completes the handshake, so the connection is ready before the
		// accept below is made.
		let deadline = Date().addingTimeInterval(5)

		while connection.state != .ready, Date() < deadline {
			try await Task.sleep(nanoseconds: 10_000_000)
		}

		guard connection.state == .ready else {
			connection.cancel()

			throw POSIXError(.ETIMEDOUT)
		}

		peer.accepted = accept(peer.listener, nil, nil)

		guard peer.accepted >= 0 else {
			connection.cancel()

			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}

		return (peer, connection)
	}

	/// Sends `bytes`, and then, if asked, a FIN: a half-close, so that what the client writes
	/// meanwhile is taken in rather than answered with a reset.
	func send(_ bytes: [UInt8], thenClose: Bool) {
		var offset = 0

		while offset < bytes.count {
			let sent = bytes[offset...].withUnsafeBytes {
				Darwin.send(accepted, $0.baseAddress, $0.count, 0)
			}

			guard sent > 0 else {
				break
			}

			offset += sent
		}

		if thenClose {
			shutdown(accepted, SHUT_WR)
		}
	}

	/// Sends `bytes`, then ends the connection with a reset: SO_LINGER on with a time of zero, then
	/// the close.
	func sendThenReset(_ bytes: [UInt8]) {
		send(bytes, thenClose: false)

		var linger = Darwin.linger(l_onoff: 1, l_linger: 0)

		setsockopt(accepted, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
		close(accepted)

		accepted = -1
	}
}

private extension NWConnection {
	/// One receive, as Network.framework completes it: how many bytes it brought and whether it
	/// said the stream was complete.
	func receiveOnce(maximumLength: Int) async -> (count: Int?, isComplete: Bool, error: NWError?) {
		await withCheckedContinuation { continuation in
			receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
				continuation.resume(returning: (content?.count, isComplete, error))
			}
		}
	}
}
#endif
