// The server's end of the kit's own dial, for the tests of how a dialled connection ends
// (SocketCancelTests, SocketDescriptorTests): a listener on 127.0.0.1 at a free port, and the
// connections it takes -- what they are sent, and whether, and when, the client's end of the stream
// comes. POSIX sockets, or WinSock. And, on POSIX, the process's own descriptors, read from outside
// the kit: which number is the kit's end of a connection, whether a number is open, and a socket of
// the test's given a number of its choosing -- the lowest number free is the one a new descriptor
// gets.

import Foundation
import Dispatch
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

struct LoopbackFailure: Error, CustomStringConvertible {
	let description: String

	init(_ description: String) {
		self.description = description
	}
}

final class LoopbackServer: @unchecked Sendable {
#if canImport(WinSDK)
	typealias Handle = SOCKET

	static let invalid = INVALID_SOCKET
#else
	typealias Handle = Int32

	static let invalid: Int32 = -1
#endif

	let listener: Handle
	let port: UInt16

	convenience init() throws {
#if canImport(WinSDK)
		try Winsock.intializeWinsock()
#endif

		let made = Self.makeSocket()

		guard made != Self.invalid else {
			throw LoopbackFailure("no socket for the listener")
		}

		try self.init(listeningOn: made)
	}

	/// A listener on `made`, a socket not yet bound, which it then owns: closed if it cannot be bound,
	/// else when the server goes.
	init(listeningOn made: Handle) throws {
		var address = sockaddr_in()
		let loopback = UInt32(0x7F00_0001).bigEndian

#if canImport(WinSDK)
		address.sin_family = ADDRESS_FAMILY(AF_INET)
		address.sin_addr.S_un.S_addr = loopback

		var length = Int32(MemoryLayout<sockaddr_in>.size)
#else
#if canImport(Darwin)
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
		address.sin_family = sa_family_t(AF_INET)
		address.sin_addr.s_addr = loopback

		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
#endif

		address.sin_port = 0

		let bound = withUnsafeMutablePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(made, $0, length) == 0 && getsockname(made, $0, &length) == 0
			}
		}

		guard bound, listen(made, 8) == 0 else {
			Self.closeHandle(made)

			throw LoopbackFailure("the listener could not be bound on 127.0.0.1")
		}

		listener = made
		port = UInt16(bigEndian: address.sin_port)
	}

	deinit {
		Self.closeHandle(listener)
	}

	/// The next connection, taken within `seconds`; nil if none came.
	func take(within seconds: Double) -> Connection? {
		let end = Date().addingTimeInterval(seconds)

		while Date() < end {
			guard Self.waitReadable(listener, milliseconds: 50) else {
				continue
			}

			let taken = Self.acceptOne(listener)

			if taken != Self.invalid {
				return Connection(taken)
			}
		}

		return nil
	}

	/// A connection the server took.
	final class Connection: @unchecked Sendable {
		let handle: Handle

		/// The other end's port: the kit's end of the connection.
		let clientPort: UInt16

		private let lock = NSLock()
		private var closed = false

		fileprivate init(_ handle: Handle) {
			self.handle = handle
			clientPort = LoopbackServer.port(of: handle, peer: true) ?? 0
		}

		deinit {
			close()
		}

		/// All of `bytes`, waiting for room as long as it takes.
		func say(_ bytes: [UInt8]) {
			var sent = 0

			while sent < bytes.count {
				let count = bytes[sent...].withUnsafeBytes { LoopbackServer.sendSome(handle, $0) }

				guard count > 0 else {
					return
				}

				sent += count
			}
		}

		/// Reads what the client sends, and throws it away, until the client's end of the stream comes
		/// -- its FIN, or a reset -- or `seconds` go by: whether the end came.
		func sawTheEnd(within seconds: Double) -> Bool {
			let end = Date().addingTimeInterval(seconds)
			var buffer = [UInt8](repeating: 0, count: 65_536)

			while Date() < end {
				guard LoopbackServer.waitReadable(handle, milliseconds: 50) else {
					continue
				}

				let count = buffer.withUnsafeMutableBytes { LoopbackServer.receiveSome(handle, $0) }

				if count <= 0 {
					return true
				}
			}

			return false
		}

		/// The connection's end, from the server: a FIN, and the descriptor given up. Once.
		func close() {
			lock.lock()

			let closing = !closed

			closed = true

			lock.unlock()

			if closing {
				LoopbackServer.closeHandle(handle)
			}
		}
	}

	// MARK: - Calls, as each platform spells them

	static func makeSocket() -> Handle {
#if canImport(Glibc)
		Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#elseif canImport(Android)
		Android.socket(AF_INET, Int32(SOCK_STREAM), 0)
#else
		socket(AF_INET, SOCK_STREAM, 0)
#endif
	}

	static func closeHandle(_ handle: Handle) {
#if canImport(WinSDK)
		_ = closesocket(handle)
#elseif canImport(Glibc)
		_ = Glibc.close(handle)
#elseif canImport(Android)
		_ = Android.close(handle)
#else
		_ = Darwin.close(handle)
#endif
	}

	private static func acceptOne(_ listener: Handle) -> Handle {
#if canImport(WinSDK)
		WinSDK.accept(listener, nil, nil)
#elseif canImport(Glibc)
		Glibc.accept(listener, nil, nil)
#elseif canImport(Android)
		Android.accept(listener, nil, nil)
#else
		Darwin.accept(listener, nil, nil)
#endif
	}

	/// Whether `handle` has something to read -- bytes, a connection, an end -- within `milliseconds`.
	static func waitReadable(_ handle: Handle, milliseconds: Int32) -> Bool {
#if canImport(WinSDK)
		var entry = WSAPOLLFD(fd: handle, events: SHORT(POLLRDNORM), revents: 0)

		return WSAPoll(&entry, 1, INT(milliseconds)) == 1
#else
		var entry = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)

		return poll(&entry, 1, milliseconds) == 1
#endif
	}

	fileprivate static func sendSome(_ handle: Handle, _ bytes: UnsafeRawBufferPointer) -> Int {
		guard let base = bytes.baseAddress else {
			return 0
		}

#if canImport(WinSDK)
		return Int(WinSDK.send(handle, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count), 0))
#elseif canImport(Glibc)
		return Glibc.send(handle, base, bytes.count, Int32(MSG_NOSIGNAL))
#elseif canImport(Android)
		return Android.send(handle, base, bytes.count, Int32(MSG_NOSIGNAL))
#else
		return Darwin.send(handle, base, bytes.count, 0)
#endif
	}

	fileprivate static func receiveSome(_ handle: Handle, _ buffer: UnsafeMutableRawBufferPointer) -> Int {
		guard let base = buffer.baseAddress else {
			return 0
		}

#if canImport(WinSDK)
		return Int(recv(handle, base.assumingMemoryBound(to: CChar.self), Int32(buffer.count), 0))
#else
		return recv(handle, base, buffer.count, 0)
#endif
	}

	/// The port of `handle`'s own end (getsockname), or of the other end (getpeername, `peer`); nil
	/// where it has none.
	static func port(of handle: Handle, peer: Bool) -> UInt16? {
		var address = sockaddr_in()

#if canImport(WinSDK)
		var length = Int32(MemoryLayout<sockaddr_in>.size)
		let family = ADDRESS_FAMILY(AF_INET)
#else
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let family = sa_family_t(AF_INET)
#endif

		let named = withUnsafeMutablePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				(peer ? getpeername(handle, $0, &length) : getsockname(handle, $0, &length)) == 0
			}
		}

		guard named, address.sin_family == family else {
			return nil
		}

		return UInt16(bigEndian: address.sin_port)
	}

	/// Whether `handle` is a socket this process has open: its type can be read.
	static func isOpen(_ handle: Handle) -> Bool {
		var type: Int32 = 0

#if canImport(WinSDK)
		var length = Int32(MemoryLayout<Int32>.size)

		let result = withUnsafeMutableBytes(of: &type) { raw in
			getsockopt(handle, SOL_SOCKET, SO_TYPE, raw.baseAddress?.assumingMemoryBound(to: CChar.self), &length)
		}

		return result == 0
#else
		var length = socklen_t(MemoryLayout<Int32>.size)

		return getsockopt(handle, SOL_SOCKET, SO_TYPE, &type, &length) == 0
#endif
	}
}

#if !canImport(WinSDK)
extension LoopbackServer {
	/// The descriptor of this process whose own end is at `clientPort` and whose other end is this
	/// server's port: the kit's end of a connection the server took. (The server's end of it is the
	/// other way round.)
	func descriptor(ofTheClientAt clientPort: UInt16) -> Int32? {
		for number in Int32(0)..<Int32(4_096) where fcntl(number, F_GETFD) != -1 {
			if Self.port(of: number, peer: false) == clientPort, Self.port(of: number, peer: true) == port {
				return number
			}
		}

		return nil
	}

	/// A socket of the test's own, given the number `wanted`: POSIX gives a new descriptor the lowest
	/// number free, so sockets are made until one has it. Every other one made on the way is closed
	/// again. Nil if the number went to some other descriptor first.
	static func takeNumber(_ wanted: Int32) -> Int32? {
		var made: [Int32] = []

		defer {
			for number in made where number != wanted {
				closeHandle(number)
			}
		}

		for _ in 0..<1_024 {
			let number = makeSocket()

			guard number >= 0 else {
				return nil
			}

			made.append(number)

			if number == wanted {
				return number
			}

			if number > wanted {
				return nil
			}
		}

		return nil
	}
}
#endif

/// A value one thread sets, once, that another reads.
final class Settled<Value>: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: Value?

	init() { }

	func settle(_ value: Value) {
		lock.lock()

		if stored == nil {
			stored = value
		}

		lock.unlock()
	}

	var value: Value? {
		lock.lock()
		defer { lock.unlock() }

		return stored
	}
}

/// Whether `condition` holds within `seconds`, looked at every hundredth of a second.
func holds(within seconds: Double, _ condition: () -> Bool) -> Bool {
	let end = Date().addingTimeInterval(seconds)

	while Date() < end {
		if condition() {
			return true
		}

		Thread.sleep(forTimeInterval: 0.01)
	}

	return condition()
}

/// How a read or a write of a connection came out, in words a test compares: "cancelled" for the
/// kit's `VNCError.connection(.cancelled)`, else what it was.
func howItEnded(_ error: Error) -> String {
	if let failure = error as? VNCError, case .connection(.cancelled) = failure {
		return "cancelled"
	}

	return "\(error)"
}
