// A whole connection against a server that is a script: the kit's own VNCConnection, handshake and
// all, handed a VNCTransport that answers its reads from bytes a test wrote and counts what it
// writes. Nothing is dialled and no socket is opened.

import Foundation
import Dispatch
@testable import RoyalVNCKit

/// A transport whose peer is a script. Ready from the start, so the connection adopts it rather
/// than starting it; at the script's end a read fails as a closed connection's does.
final class ScriptedTransport: VNCTransport, @unchecked Sendable {
	private let lock = NSLock()
	private let script: [UInt8]
	private var offset = 0
	private var cancelled = false
	private var written = 0

	init(script: [UInt8]) {
		self.script = script
	}

	/// How many bytes the connection has written.
	var writtenByteCount: Int {
		lock.lock()
		defer { lock.unlock() }

		return written
	}

	var isTransportReady: Bool {
		lock.lock()
		defer { lock.unlock() }

		return !cancelled
	}

	var transportState: VNCTransportState {
		isTransportReady ? .ready : .cancelled
	}

	func setTransportStateHandler(_ handler: VNCTransportStateHandler?) { }

	func startTransport(queue: DispatchQueue) { }

	func cancelTransport() {
		lock.lock()
		cancelled = true
		lock.unlock()
	}

	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data {
		lock.lock()
		defer { lock.unlock() }

		let minimum = max(1, minimumLength)

		guard !cancelled,
			  maximumLength >= minimum,
			  script.count - offset >= minimum else {
			throw VNCError.connection(.closed)
		}

		let count = min(maximumLength, script.count - offset)
		let chunk = Data(script[offset..<offset + count])

		offset += count

		return chunk
	}

	func writeTransport(data: Data) async throws {
		lock.lock()
		defer { lock.unlock() }

		guard !cancelled else {
			throw VNCError.connection(.closed)
		}

		written += data.count
	}
}

/// What settled a connection first: a framebuffer, or a disconnection and its reason.
final class ConnectionOutcome: VNCConnectionDelegate, @unchecked Sendable {
	enum Outcome: CustomStringConvertible {
		case framebuffer(width: Int, height: Int)
		case disconnected(String)
		case nothing

		var description: String {
			switch self {
				case .framebuffer(let width, let height): "a \(width)x\(height) framebuffer"
				case .disconnected(let reason): "disconnected: \(reason)"
				case .nothing: "nothing"
			}
		}
	}

	private let lock = NSLock()
	private var settled: Outcome?

	private func settle(_ outcome: Outcome) {
		lock.lock()

		if settled == nil {
			settled = outcome
		}

		lock.unlock()
	}

	private var current: Outcome? {
		lock.lock()
		defer { lock.unlock() }

		return settled
	}

	/// Polls rather than waits, so that no thread of the test's own is held.
	func outcome(within seconds: Double) async -> Outcome {
		let deadline = Date().addingTimeInterval(seconds)

		while Date() < deadline {
			if let current {
				return current
			}

			try? await Task.sleep(nanoseconds: 20_000_000)
		}

		return current ?? .nothing
	}

	func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
		guard connectionState.status == .disconnected else {
			return
		}

		settle(.disconnected(connectionState.error.map { "\($0)" } ?? "no error"))
	}

	func connection(_ connection: VNCConnection,
					credentialFor authenticationType: VNCAuthenticationType,
					completion: @escaping (VNCCredential?) -> Void) {
		completion(nil)
	}

	func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
		settle(.framebuffer(width: Int(framebuffer.size.width), height: Int(framebuffer.size.height)))
	}

	func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) { }

	func connection(_ connection: VNCConnection,
					didUpdateFramebuffer framebuffer: VNCFramebuffer,
					x: UInt16, y: UInt16, width: UInt16, height: UInt16) { }

	func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) { }
}

enum ScriptedServer {
	/// A server that speaks RFB 3.8 (RFC 6143 7.1.1), offers security type None alone (7.1.2,
	/// 7.2.1), reports success (7.1.3), and then sends ServerInit (7.3.2) for a framebuffer of
	/// `width` by `height` in 32-bit true colour -- and nothing more.
	static func serverInit(width: UInt16, height: UInt16) -> [UInt8] {
		var stream = ServerStream()

		stream.append(Array("RFB 003.008\n".utf8))
		stream.u8(1)                          // number-of-security-types
		stream.u8(1)                          // None
		stream.u32(0)                         // SecurityResult: OK
		stream.u16(width)
		stream.u16(height)
		stream.append([32, 24, 0, 1])         // bits-per-pixel, depth, big-endian, true-colour
		stream.u16(255); stream.u16(255); stream.u16(255)
		stream.append([16, 8, 0, 0, 0, 0])    // shifts, padding
		stream.u32(4)
		stream.append(Array("test".utf8))

		return stream.bytes
	}

	/// Connects a VNCConnection to that server and reports what settled it, and how many bytes
	/// the client wrote by then.
	static func connect(width: UInt16, height: UInt16) async throws -> (outcome: ConnectionOutcome.Outcome, written: Int) {
		let transport = ScriptedTransport(script: serverInit(width: width, height: height))
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

		// A framebuffer of up to 64 MiB: see CappedAllocator.
		let connection = VNCConnection(settings: settings,
									   logger: QuietLogger(),
									   framebufferAllocator: CappedAllocator(limit: 64 * 1024 * 1024),
									   context: nil)

		connection.transportProvider = { _, _ in transport }
		connection.delegate = watcher
		connection.connect()

		let outcome = await watcher.outcome(within: 10)
		let written = transport.writtenByteCount

		connection.disconnect()

		return (outcome, written)
	}
}

/// A malloc allocator that refuses, and records, anything over `limit` bytes. A test of a size that
/// should be refused before anything is allocated asks this one, so that should the refusal ever go,
/// the test fails instead of zeroing up to seventeen gigabytes of whoever runs it.
final class CappedAllocator: VNCFramebufferAllocator, @unchecked Sendable {
	struct Refused: Error {
		let size: Int
	}

	let limit: Int

	private let allocator = VNCFramebufferMallocAllocator()
	private let lock = NSLock()
	private var refusedSizes = [Int]()

	init(limit: Int) {
		self.limit = limit
	}

	/// The sizes asked for past the limit.
	var refused: [Int] {
		lock.lock()
		defer { lock.unlock() }

		return refusedSizes
	}

	func allocate(size: Int) throws -> UnsafeMutableRawPointer {
		guard size <= limit else {
			lock.lock()
			refusedSizes.append(size)
			lock.unlock()

			throw Refused(size: size)
		}

		return try allocator.allocate(size: size)
	}

	func deallocate(buffer: UnsafeMutableRawPointer) {
		allocator.deallocate(buffer: buffer)
	}

	func lockReadOnly() {
		allocator.lockReadOnly()
	}

	func unlockReadOnly() {
		allocator.unlockReadOnly()
	}

	func lockReadWrite() {
		allocator.lockReadWrite()
	}

	func unlockReadWrite() {
		allocator.unlockReadWrite()
	}
}
