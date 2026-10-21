// A connection the kit dials with its own socket ends when it is cancelled, not when its object
// happens to go. SocketNetworkConnection is the dial on Linux, Windows and Android (on Apple
// platforms the kit dials with Network.framework, and the class is tested here all the same). Its
// cancel() did nothing, and the socket was closed only in Socket's deinit, which a read waiting for
// a server that sends nothing holds off for as long as the server stays silent: so an embedder that
// ended a session on a still screen, or abandoned an attempt that a server had stopped answering,
// left the TCP connection open until the server next sent on it or closed it, and the server
// counted a viewer that had gone. (What came then was not served: BufferedTransport serves nothing
// after a cancel.)
//
// Now a cancel ends the connection at once: a read or a write waiting on another thread, and a
// connect under way, return; the server is sent the end of the stream; and the descriptor is closed
// once nothing uses it, and never again (the release closes nothing more). Each case runs against a
// server of its own on loopback (LoopbackServer), from outside the kit -- the server's end of the
// connection, and on POSIX the process's own descriptors. SocketDescriptorTests holds what needs the
// kit's own seams: a descriptor never closed while a call still uses it.

import Foundation
import Dispatch
import XCTest
@testable import RoyalVNCKit

#if canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#endif

final class SocketCancelTests: XCTestCase {
	/// A SocketNetworkConnection started on `queue` (concurrent, as VNCConnection's is, so that a read
	/// and a write can wait at once) to `server`, once it is ready.
	private func readyConnection(to server: LoopbackServer,
							queue: DispatchQueue = DispatchQueue(label: "SocketCancelTests", attributes: .concurrent)) throws -> SocketNetworkConnection {
		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "127.0.0.1",
																					 port: server.port))

		connection.start(queue: queue)

		guard holds(within: 5, { connection.isReady }) else {
			connection.cancel()

			throw LoopbackFailure("the connection was not ready within 5 s: \(connection.status)")
		}

		return connection
	}

	/// A read of `connection`, started on a task of its own; how it ended, once it has.
	private func read(_ connection: SocketNetworkConnection) -> Settled<String> {
		let ended = Settled<String>()

		Task.detached {
			do {
				let data = try await connection.read(minimumLength: 1, maximumLength: 1)

				ended.settle("read \(data.count) bytes")
			} catch {
				ended.settle(howItEnded(error))
			}
		}

		return ended
	}

	/// A write of `data` to `connection`, started on a task of its own; how it ended, once it has.
	private func write(_ data: Data, to connection: SocketNetworkConnection) -> Settled<String> {
		let ended = Settled<String>()

		Task.detached {
			do {
				try await connection.write(data: data)

				ended.settle("written")
			} catch {
				ended.settle(howItEnded(error))
			}
		}

		return ended
	}

	/// A read waiting for a server that says nothing -- a still screen, a server that has stopped
	/// answering -- returns, cancelled, when the connection is cancelled, and the server is sent the
	/// end of the stream then. (It waited in `recv` until the server sent or closed.)
	func testACancelEndsAReadWaitingOnASilentServer() throws {
		let server = try LoopbackServer()
		let connection = try readyConnection(to: server)
		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		// Its close ends a read the cancel did not.
		defer { taken.close() }

		let reading = read(connection)

		Thread.sleep(forTimeInterval: 0.3)

		XCTAssertNil(reading.value, "the read waits: the server says nothing")

		connection.cancel()

		XCTAssertTrue(holds(within: 2) { reading.value != nil }, "the read ends with the cancel")
		XCTAssertEqual(reading.value, "cancelled")
		XCTAssertTrue(taken.sawTheEnd(within: 2), "the server is sent the end of the stream")
	}

	/// A write waiting for room -- the server reads nothing, so its buffers and this side's fill --
	/// returns, cancelled, when the connection is cancelled. (A send blocked until the server read or
	/// closed.) Written a mebibyte at a time until one waits: a single large send can be taken whole
	/// (on Windows one of 64 MB was), so only a later one waits.
	func testACancelEndsAWriteWaitingForRoom() throws {
		let server = try LoopbackServer()
		let connection = try readyConnection(to: server)
		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		let chunk = Data(repeating: 0x5A, count: 1 << 20)
		var waiting: Settled<String>?

		for _ in 0..<1_024 {
			let writing = write(chunk, to: connection)

			guard holds(within: 1, { writing.value != nil }) else {
				waiting = writing

				break
			}

			guard writing.value == "written" else {
				return XCTFail("a write failed before the cancel: \(writing.value ?? "")")
			}
		}

		let writing = try XCTUnwrap(waiting, "no write waited for room in a gibibyte")

		connection.cancel()

		XCTAssertTrue(holds(within: 2) { writing.value != nil }, "the write ends with the cancel")
		XCTAssertEqual(writing.value, "cancelled")
	}

	/// A connect to an address nothing answers on -- TEST-NET-1 (RFC 5737), whose packets go nowhere
	/// -- waits for the system's SYN retries; the cancel ends it. The dial runs on a serial queue of
	/// its own here, so the queue is free again once the dial has returned. (The dial held its thread
	/// until the system gave up.)
	func testACancelEndsAConnectUnderWay() throws {
		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "192.0.2.1",
																					 port: 5900))
		let dial = DispatchQueue(label: "SocketCancelTests.dial")

		connection.start(queue: dial)

		Thread.sleep(forTimeInterval: 0.5)

		if case .failed(let error) = connection.status {
			throw XCTSkip("the network answered a connect to 192.0.2.1 at once (\(error)): no connect to cancel")
		}

		XCTAssertFalse(connection.isReady, "nothing answers 192.0.2.1")

		connection.cancel()

		let free = DispatchSemaphore(value: 0)

		dial.async { free.signal() }

		XCTAssertEqual(free.wait(timeout: .now() + 2), .success, "the dial returns with the cancel")
	}

	/// A connection cancelled before it is started dials nothing: a cancelled connection stays so.
	func testAConnectionCancelledBeforeItStartsDialsNothing() throws {
		let server = try LoopbackServer()
		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "127.0.0.1",
																					 port: server.port))

		connection.cancel()
		connection.start(queue: DispatchQueue(label: "SocketCancelTests"))

		XCTAssertNil(server.take(within: 1), "nothing dialled")

		guard case .cancelled = connection.status else {
			return XCTFail("cancelled, not \(connection.status)")
		}
	}

	/// After a cancel a read and a write fail, cancelled, at once, the server silent or not. (A read
	/// waited in `recv`, and a write was sent.)
	func testAReadAndAWriteAfterACancelFailAtOnce() throws {
		let server = try LoopbackServer()
		let connection = try readyConnection(to: server)
		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		connection.cancel()

		let reading = read(connection)
		let writing = write(Data([1, 2, 3]), to: connection)

		XCTAssertTrue(holds(within: 2) { reading.value != nil && writing.value != nil },
					  "the read and the write end at once: \(reading.value ?? "waiting"), \(writing.value ?? "waiting")")
		XCTAssertEqual(reading.value, "cancelled")
		XCTAssertEqual(writing.value, "cancelled")
	}

	/// The status handler is told of the cancel, once, however often the connection is cancelled, and
	/// the connection says it is cancelled from then on, as an NWConnection does.
	func testTheCancelIsReportedOnce() throws {
		let server = try LoopbackServer()
		let lock = NSLock()
		var reported: [String] = []

		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "127.0.0.1",
																					 port: server.port))

		connection.setStatusUpdateHandler { status in
			let name: String

			switch status {
				case .cancelled: name = "cancelled"
				case .ready: name = "ready"
				case .preparing: name = "preparing"
				case .failed: name = "failed"
				default: name = "other"
			}

			lock.lock()
			reported.append(name)
			lock.unlock()
		}

		connection.start(queue: DispatchQueue(label: "SocketCancelTests", attributes: .concurrent))

		// Told, not only ready: the status is set before the handler hears of it.
		XCTAssertTrue(holds(within: 5) { lock.lock(); defer { lock.unlock() }; return reported.contains("ready") }, "ready")

		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		connection.cancel()
		connection.cancel()

		Thread.sleep(forTimeInterval: 0.2)

		lock.lock()
		let told = reported
		lock.unlock()

		XCTAssertEqual(told, ["preparing", "ready", "cancelled"])

		guard case .cancelled = connection.status else {
			return XCTFail("cancelled, not \(connection.status)")
		}
	}

	/// The kit's own disconnect, end to end: a VNCConnection that dials for itself -- with this socket
	/// on Linux, Windows and Android, with Network.framework on Apple platforms -- connected to a server
	/// that sends nothing after ServerInit (a still screen), and disconnected. The server is sent the end
	/// of the stream at once: through BufferedTransport and SocketConnectionTransport to the socket.
	func testADisconnectEndsTheConnectionAtTheServerAtOnce() throws {
		let server = try LoopbackServer()
		let watcher = ConnectionOutcome()

		let settings = VNCConnection.Settings(isDebugLoggingEnabled: false,
											  hostname: "127.0.0.1",
											  port: server.port,
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

		connection.delegate = watcher
		connection.connect()

		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		// The server's whole side of an RFB 3.8 handshake with security type None, at once -- the kit
		// reads it in order -- and then nothing.
		taken.say(ScriptedServer.serverInit(width: 32, height: 24))

		let connected = Settled<String>()

		Task.detached {
			connected.settle("\(await watcher.outcome(within: 10))")
		}

		XCTAssertTrue(holds(within: 11) { connected.value != nil })
		XCTAssertEqual(connected.value, "a 32x24 framebuffer", "connected")

		// Its first update request and the rest are sent, and its reads wait for the server.
		Thread.sleep(forTimeInterval: 0.3)

		connection.disconnect()

		XCTAssertTrue(taken.sawTheEnd(within: 2), "the server is sent the end of the stream at the disconnect")
	}

#if !canImport(WinSDK)
	/// With nothing using it, the cancel closes the descriptor itself; the release closes nothing more
	/// -- by then the number may be another socket's, here one of the test's own. (The cancel closed
	/// nothing, and the release closed the number.) POSIX, where a number is read from outside the kit
	/// and given out again lowest first.
	func testACancelClosesTheDescriptorAndTheReleaseClosesNothingMore() throws {
		let server = try LoopbackServer()
		var connection: SocketNetworkConnection? = try readyConnection(to: server)
		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		let number = try XCTUnwrap(server.descriptor(ofTheClientAt: taken.clientPort), "the kit's end of the connection")

		connection?.cancel()

		XCTAssertFalse(LoopbackServer.isOpen(number), "the cancel closes the descriptor: nothing uses it")

		let mine = try XCTUnwrap(LoopbackServer.takeNumber(number), "the number, free again, given to a socket of the test's")

		defer { LoopbackServer.closeHandle(mine) }

		weak var released = connection

		connection = nil

		XCTAssertTrue(holds(within: 2) { released == nil }, "the connection let go of")
		XCTAssertTrue(LoopbackServer.isOpen(mine), "the release closes nothing more: the number is the test's socket's now")
	}

	/// With a read waiting at the cancel, the descriptor is closed once the read has returned, and the
	/// release closes nothing more. POSIX, as above.
	func testACancelDuringAReadClosesTheDescriptorOnceTheReadHasReturned() throws {
		let server = try LoopbackServer()
		var connection: SocketNetworkConnection? = try readyConnection(to: server)
		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		let number = try XCTUnwrap(server.descriptor(ofTheClientAt: taken.clientPort), "the kit's end of the connection")
		let reading = read(try XCTUnwrap(connection))

		Thread.sleep(forTimeInterval: 0.3)

		XCTAssertNil(reading.value, "the read waits: the server says nothing")

		connection?.cancel()

		XCTAssertTrue(holds(within: 2) { reading.value != nil }, "the read ends with the cancel")
		XCTAssertEqual(reading.value, "cancelled")
		XCTAssertTrue(holds(within: 1) { !LoopbackServer.isOpen(number) }, "the descriptor closed, the read returned")

		let mine = try XCTUnwrap(LoopbackServer.takeNumber(number), "the number, free again, given to a socket of the test's")

		defer { LoopbackServer.closeHandle(mine) }

		weak var released = connection

		connection = nil

		XCTAssertTrue(holds(within: 2) { released == nil }, "the connection let go of")
		XCTAssertTrue(LoopbackServer.isOpen(mine), "the release closes nothing more: the number is the test's socket's now")
	}
#endif
}
