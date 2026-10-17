// Every connection the kit dials asks for TCP keepalive (TCPKeepalive): probes after
// 30 s with nothing from the server, every 5 s, given up after 3. A server may send
// nothing while its screen is still (RFC 6143 §7.5.3: "there may be an indefinite
// period between the FramebufferUpdateRequest and the FramebufferUpdate"), and the kit
// asks again only after an update; with nothing in flight, a server that went away
// without closing was never noticed.
//
// On Apple platforms the dialled transport is an NWConnection, whose parameters say what
// it asked Network.framework for; elsewhere a Socket, whose options are read back from
// the socket itself. The numbers expected are written here, not taken from TCPKeepalive.

import XCTest
@testable import RoyalVNCKit

#if canImport(Network)
import Network
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#endif

final class KeepaliveTests: XCTestCase {
#if canImport(Network)
	func testADialledConnectionAsksForKeepalive() throws {
		let settings = NetworkConnectionSettings(connectionTimeout: 15, host: "127.0.0.1", port: 5900)
		let connection = NWConnection(settings: settings)

		defer { connection.cancel() }

		let tcp = try XCTUnwrap(connection.parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)

		XCTAssertTrue(tcp.enableKeepalive, "keepalive asked for")
		XCTAssertEqual(tcp.keepaliveIdle, 30, "30 s with nothing from the server before the first probe")
		XCTAssertEqual(tcp.keepaliveInterval, 5, "every 5 s")
		XCTAssertEqual(tcp.keepaliveCount, 3, "given up after 3")
		XCTAssertEqual(tcp.connectionTimeout, 15, "and the connection timeout as it was")
	}
#endif

	func testASocketHasKeepalive() throws {
#if canImport(WinSDK)
		try Winsock.intializeWinsock()

		let tcp = Int32(IPPROTO_TCP.rawValue)
		let (idle, interval, count): (Int32, Int32, Int32) = (3, 17, 16)
#elseif canImport(Glibc) || canImport(Android)
		let tcp = Int32(IPPROTO_TCP)
		let (idle, interval, count): (Int32, Int32, Int32) = (TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT)
#elseif canImport(Darwin)
		let tcp: Int32 = IPPROTO_TCP
		let (idle, interval, count): (Int32, Int32, Int32) = (TCP_KEEPALIVE, TCP_KEEPINTVL, TCP_KEEPCNT)
#endif

		let socket = try Socket(addressInfo: AddressInfo(host: "127.0.0.1", port: 5900))

		// SO_KEEPALIVE as on or off: Darwin reads back the option's flag bit, not 1.
		XCTAssertEqual(socket.intOption(level: SOL_SOCKET, name: SO_KEEPALIVE).map { $0 != 0 }, true, "keepalive on")
		XCTAssertEqual(socket.intOption(level: tcp, name: idle), 30, "30 s with nothing from the server before the first probe")
		XCTAssertEqual(socket.intOption(level: tcp, name: interval), 5, "every 5 s")
		XCTAssertEqual(socket.intOption(level: tcp, name: count), 3, "given up after 3")
	}
}
