// The descriptor of a socket the kit dials is closed exactly once, and never while another thread can
// still use its number -- by then the number may be another socket's of the process, whose
// connection a stale shutdown, read, write or close would end or talk on. (In an embedder, a
// transport that shut down a number its reader had already closed ended the listen of whichever
// socket had been given the number since.) A cancel that comes while a call uses the descriptor
// leaves it open, and the last call out closes it; nothing after the cancel uses it again -- no
// call, no second cancel, not the release. And a cancel that comes while the dial is under way
// leaves nothing connected. What a test cannot see from outside the kit is seen through its own
// seams: `Socket.beforeWaitingForTests`, which holds a call as it is about to wait, the descriptor in
// use; `SocketNetworkConnection.beforeDialingForTests`, which holds a dial as it begins; and `Socket`
// itself. SocketCancelTests holds the rest, from outside.

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

final class SocketDescriptorTests: XCTestCase {
	override func tearDown() {
		Socket.beforeWaitingForTests = nil
		SocketNetworkConnection.beforeDialingForTests = nil

		super.tearDown()
	}

	/// A cancel that comes with the dial under way -- held as it begins, before its socket is made --
	/// leaves nothing connected: the socket the dial then makes is never connected, and the connection
	/// stays cancelled.
	func testACancelDuringTheDialConnectsNothing() throws {
		let server = try LoopbackServer()
		let began = DispatchSemaphore(value: 0)
		let letGo = DispatchSemaphore(value: 0)

		SocketNetworkConnection.beforeDialingForTests = {
			began.signal()

			_ = letGo.wait(timeout: .now() + 10)
		}

		defer { letGo.signal() }

		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "127.0.0.1",
																					 port: server.port))
		let dial = DispatchQueue(label: "SocketDescriptorTests.dial")

		connection.start(queue: dial)

		XCTAssertEqual(began.wait(timeout: .now() + 5), .success, "the dial began, and is held")

		connection.cancel()
		letGo.signal()

		let returned = DispatchSemaphore(value: 0)

		dial.async { returned.signal() }

		XCTAssertEqual(returned.wait(timeout: .now() + 5), .success, "the dial returned")
		XCTAssertNil(server.take(within: 1), "nothing connected")

		guard case .cancelled = connection.status else {
			return XCTFail("cancelled, not \(connection.status)")
		}
	}

	/// A connection cancelled before it is started begins no dial at all: not even a socket is made.
	func testAConnectionCancelledBeforeItStartsBeginsNoDial() throws {
		let began = Settled<Bool>()

		SocketNetworkConnection.beforeDialingForTests = { began.settle(true) }

		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "127.0.0.1",
																					 port: 9))
		let dial = DispatchQueue(label: "SocketDescriptorTests.dial")

		connection.cancel()
		connection.start(queue: dial)

		let returned = DispatchSemaphore(value: 0)

		dial.async { returned.signal() }

		XCTAssertEqual(returned.wait(timeout: .now() + 5), .success)
		XCTAssertNil(began.value, "no dial began")
	}

	/// A cancel while a read waits -- held as it is about to wait, so that it is still under way --
	/// shuts the connection down at once, so the server is sent the end of the stream then, and leaves
	/// the descriptor open while the read uses it; the read, let go, returns cancelled and closes it.
	func testACancelLeavesTheDescriptorToTheCallStillUsingIt() throws {
		let server = try LoopbackServer()
		let connection = SocketNetworkConnection(settings: NetworkConnectionSettings(connectionTimeout: 15,
																					 host: "127.0.0.1",
																					 port: server.port))

		connection.start(queue: DispatchQueue(label: "SocketDescriptorTests", attributes: .concurrent))

		XCTAssertTrue(holds(within: 5) { connection.isReady }, "ready")

		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		let clientPort = taken.clientPort
		let held = DispatchSemaphore(value: 0)
		let letGo = DispatchSemaphore(value: 0)
		let holding = Settled<Socket.NativeSocket>()

		Socket.beforeWaitingForTests = { socket in
			guard holding.value == nil,
				  LoopbackServer.port(of: socket.nativeSocket, peer: false) == clientPort else {
				return
			}

			holding.settle(socket.nativeSocket)
			held.signal()

			_ = letGo.wait(timeout: .now() + 10)
		}

		defer { letGo.signal() }

		let reading = Settled<String>()

		Task.detached {
			do {
				let data = try await connection.read(minimumLength: 1, maximumLength: 1)

				reading.settle("read \(data.count) bytes")
			} catch {
				reading.settle(howItEnded(error))
			}
		}

		XCTAssertEqual(held.wait(timeout: .now() + 5), .success, "the read, about to wait, held")

		let number = try XCTUnwrap(holding.value)

		connection.cancel()

		XCTAssertTrue(LoopbackServer.isOpen(number), "the descriptor open: the read still uses it")
		XCTAssertTrue(taken.sawTheEnd(within: 2), "the server sent the end at the cancel, the read still under way")
		XCTAssertNil(reading.value, "the read still held")

		letGo.signal()

		XCTAssertTrue(holds(within: 2) { reading.value != nil }, "the read returns")
		XCTAssertEqual(reading.value, "cancelled")
		XCTAssertTrue(holds(within: 1) { !LoopbackServer.isOpen(number) }, "and the descriptor is closed as it does")
	}

#if !canImport(WinSDK)
	/// After a cancel nothing of the socket's uses the number again, here given to a listener of the
	/// test's: a receive, a send, an option read, a connect and a second cancel each fail or do nothing
	/// without a call on it, and the release closes nothing. The listener is open and listening
	/// after them all -- on Linux a shutdown of a listening socket ends its listen. POSIX, where a
	/// number is given out again lowest first.
	func testNothingAfterTheCancelUsesTheNumberAgain() throws {
		let server = try LoopbackServer()
		var socket: Socket? = try Socket(addressInfo: AddressInfo(host: "127.0.0.1", port: server.port))

		try socket?.connect()

		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		let number = try XCTUnwrap(socket?.nativeSocket)

		socket?.cancel()

		XCTAssertFalse(LoopbackServer.isOpen(number), "closed by the cancel: nothing used it")

		let mine = try XCTUnwrap(LoopbackServer.takeNumber(number), "the number, free again, given to a socket of the test's")
		let listener = try LoopbackServer(listeningOn: mine)

		var buffer = [UInt8](repeating: 0, count: 16)

		XCTAssertEqual(socket?.receive(buffer: &buffer), .cancelled, "a receive: cancelled")
		XCTAssertEqual(socket?.send(buffer: [1, 2, 3]), .cancelled, "a send: cancelled")
		XCTAssertNil(socket?.intOption(level: SOL_SOCKET, name: SO_TYPE), "an option read: none")
		XCTAssertThrowsError(try socket?.connect(), "a connect: cancelled")

		socket?.cancel()

		weak var released = socket

		socket = nil

		XCTAssertNil(released, "the socket let go of")
		XCTAssertTrue(LoopbackServer.isOpen(mine), "the test's listener open")

		let client = try Socket(addressInfo: AddressInfo(host: "127.0.0.1", port: listener.port))

		try client.connect()

		XCTAssertNotNil(listener.take(within: 2), "and listening")
	}

	/// A socket never cancelled is closed when it is let go of, as it always was. POSIX.
	func testASocketNeverCancelledIsClosedWhenLetGoOf() throws {
		let server = try LoopbackServer()
		var socket: Socket? = try Socket(addressInfo: AddressInfo(host: "127.0.0.1", port: server.port))

		try socket?.connect()

		let taken = try XCTUnwrap(server.take(within: 5), "the server took the connection")

		defer { taken.close() }

		let number = try XCTUnwrap(socket?.nativeSocket)

		XCTAssertTrue(LoopbackServer.isOpen(number))

		socket = nil

		XCTAssertFalse(LoopbackServer.isOpen(number), "closed when let go of")
		XCTAssertTrue(taken.sawTheEnd(within: 2), "and the server sent the end")
	}
#endif
}
