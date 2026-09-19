#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

#if canImport(Network)
import Network
#endif

/// Where a transport is in its lifecycle.
///
/// A public mirror of the internal `NetworkConnectionStatus`, so that supplying
/// a transport does not require the kit's internals to become API.
public enum VNCTransportState {
	/// Created, not started.
	case setup

	/// Starting.
	case preparing

	/// Established, and ready to carry RFB.
	case ready

	/// Not usable for now. The connection treats this as a failure.
	case waiting(_ error: any Error)

	/// Failed.
	case failed(_ error: any Error)

	/// Cancelled.
	case cancelled
}

public typealias VNCTransportStateHandler = (_ state: VNCTransportState) -> Void

/// A byte stream that RFB can run over.
///
/// `VNCConnection` normally dials its own connection from `settings.hostname`
/// and `settings.port`. Conform to this and set
/// ``VNCConnection/transportProvider`` to supply one instead.
///
/// The point is that some transports cannot be expressed as a dial. Three are
/// ordinary requirements rather than exotica:
///
/// * **A repeater or proxy preamble.** Bytes must be exchanged before RFB
///   begins, on the same stream, and the RFB handshake must not see them.
/// * **A reverse (listening) connection.** The server dials the viewer, so the
///   transport arrives from `accept(2)` — a file descriptor. Network.framework
///   has no constructor that takes one, which is precisely why this protocol
///   exists rather than a hook typed to a concrete connection class.
/// * **A tunnel.** An SSH channel is a byte stream that no socket API created.
///
/// Only six members. Everything RFB actually reads — integers, strings, padding,
/// buffered frame data — is built on ``read(minimumLength:maximumLength:)`` by
/// the kit, so a conformer never implements it.
///
/// A transport may be handed over already established, in which case the
/// connection adopts it rather than starting it again. That is what makes a
/// preamble possible: complete it, then hand over a live stream.
/// `Sendable` because a transport genuinely is used from more than one thread:
/// the kit reads on the connection's task and writes from the queue that drains
/// client-to-server messages, and VeNCrypt hands a live transport to an
/// embedder's async closure to be wrapped in TLS. Conformers already carry
/// their own locks; this states the contract they were already keeping.
public protocol VNCTransport: AnyObject, Sendable {
	/// Whether the transport is established and can carry bytes now.
	var isTransportReady: Bool { get }

	/// Where the transport is in its lifecycle.
	var transportState: VNCTransportState { get }

	/// Installs the handler the connection uses to follow the transport.
	///
	/// Called with `nil` to remove it. A transport that is already `.ready` when
	/// a handler is installed is not required to replay that — the connection
	/// checks ``transportState`` as well, precisely because replaying is not
	/// something every transport can do.
	func setTransportStateHandler(_ handler: VNCTransportStateHandler?)

	/// Starts the transport, if it has not been started already.
	func startTransport(queue: DispatchQueue)

	/// Tears the transport down.
	func cancelTransport()

	/// Reads between `minimumLength` and `maximumLength` bytes.
	///
	/// Must not return fewer than `minimumLength`, and **must not return more
	/// than `maximumLength`**. The upper bound is load-bearing: RFB reads
	/// fixed-size messages, and extra bytes desynchronise the stream.
	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data

	/// Writes `data` in full.
	func writeTransport(data: Data) async throws
}

// MARK: - Network.framework

#if canImport(Network)
/// Carries an `NWConnection` as a ``VNCTransport``.
///
/// A wrapper rather than a conformance on `NWConnection` itself. Conforming
/// Apple's type to a public protocol would force the kit's internal `isReady`,
/// `read` and `write` to become public members *of `NWConnection`*, which would
/// put them on a system type for every module that imports this one. Wrapping
/// keeps that namespace clean at the cost of one allocation per connection.
public final class NWConnectionTransport: VNCTransport {
	public let connection: NWConnection

	public init(_ connection: NWConnection) {
		self.connection = connection
	}

	public var isTransportReady: Bool { connection.state == .ready }

	public var transportState: VNCTransportState {
		Self.state(from: connection.state)
	}

	public func setTransportStateHandler(_ handler: VNCTransportStateHandler?) {
		guard let handler else {
			connection.stateUpdateHandler = nil

			return
		}

		connection.stateUpdateHandler = { state in
			handler(Self.state(from: state))
		}
	}

	public func startTransport(queue: DispatchQueue) {
		connection.start(queue: queue)
	}

	public func cancelTransport() {
		connection.cancel()
	}

	public func readTransport(minimumLength: Int,
							  maximumLength: Int) async throws -> Data {
		try await connection.read(minimumLength: minimumLength,
								  maximumLength: maximumLength)
	}

	public func writeTransport(data: Data) async throws {
		try await connection.write(data: data)
	}

	private static func state(from state: NWConnection.State) -> VNCTransportState {
		switch state {
			case .setup: .setup
			case .waiting(let error): .waiting(error)
			case .preparing: .preparing
			case .ready: .ready
			case .failed(let error): .failed(error)
			case .cancelled: .cancelled
			@unknown default: .setup
		}
	}
}
#endif

// MARK: - The POSIX connection

/// Carries the kit's socket connection as a ``VNCTransport``.
///
/// Internal: it exists so the no-provider path has a transport to use on
/// platforms without Network.framework, not as something to hand out.
final class SocketConnectionTransport: VNCTransport {
	private let connection: SocketNetworkConnection

	init(_ connection: SocketNetworkConnection) {
		self.connection = connection
	}

	var isTransportReady: Bool { connection.isReady }

	var transportState: VNCTransportState {
		Self.state(from: connection.status)
	}

	func setTransportStateHandler(_ handler: VNCTransportStateHandler?) {
		guard let handler else {
			connection.setStatusUpdateHandler(nil)

			return
		}

		connection.setStatusUpdateHandler { status in
			handler(Self.state(from: status))
		}
	}

	func startTransport(queue: DispatchQueue) { connection.start(queue: queue) }
	func cancelTransport() { connection.cancel() }

	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data {
		try await connection.read(minimumLength: minimumLength,
								  maximumLength: maximumLength)
	}

	func writeTransport(data: Data) async throws {
		try await connection.write(data: data)
	}

	private static func state(from status: NetworkConnectionStatus) -> VNCTransportState {
		switch status {
			case .setup: .setup
			case .preparing: .preparing
			case .ready: .ready
			case .waiting(let error): .waiting(error)
			case .failed(let error): .failed(error)
			case .cancelled: .cancelled
			case .unknown: .setup
		}
	}
}

// MARK: - Adapting a transport to the kit's internal connection

/// Carries a ``VNCTransport`` as the kit's internal `NetworkConnection`.
///
/// Everything the kit reads and writes is defined on `NetworkConnection` and its
/// default implementations, which are built from `read(minimumLength:maximumLength:)`
/// and `write(data:)`. So this forwards six members and inherits the rest.
///
/// It exists so that `VNCConnection.connection` stays one concrete type. Letting
/// an embedder supply an arbitrary conformer would otherwise force that property
/// to an existential, which would ripple through the forty-odd files that take a
/// connection as a generic constraint.
final class TransportNetworkConnection: NetworkConnection {
	/// A `var` so a security type can upgrade the stream in place.
	///
	/// VeNCrypt (type 19) negotiates over the plain connection and then wraps
	/// everything after it in TLS. There is no point at which a TLS connection
	/// could have been dialled instead: the bytes that decide whether TLS
	/// happens at all have already crossed this transport.
	private(set) var transport: any VNCTransport

	init(transport: any VNCTransport) {
		self.transport = transport
	}

	/// Puts a new transport in place of the current one, keeping the status
	/// handler pointed at it.
	///
	/// The caller must not have a read or write in flight. In practice the only
	/// caller is a security type's handshake, which is strictly sequential --
	/// it has just read an acknowledgement and will not read again until the
	/// upgrade returns.
	func replaceTransport(with replacement: any VNCTransport) {
		let handler = statusUpdateHandler

		transport.setTransportStateHandler(nil)
		transport = replacement

		// Re-installed rather than left behind: the connection follows the
		// transport's lifecycle through this, and after a swap it would
		// otherwise be following a transport nothing writes to.
		setStatusUpdateHandler(handler)
	}

	/// Kept so `replaceTransport` can re-install it.
	private var statusUpdateHandler: NetworkConnectionStatusUpdateHandler?

	/// The default transport for this platform, dialled from `settings`.
	init(settings: NetworkConnectionSettings) {
#if canImport(Network)
		self.transport = NWConnectionTransport(NWConnection(settings: settings))
#else
		self.transport = SocketConnectionTransport(SocketNetworkConnection(settings: settings))
#endif
	}

	var status: NetworkConnectionStatus {
		switch transport.transportState {
			case .setup: .setup
			case .preparing: .preparing
			case .ready: .ready
			case .waiting(let error): .waiting(error)
			case .failed(let error): .failed(error)
			case .cancelled: .cancelled
		}
	}

	var isReady: Bool { transport.isTransportReady }

	func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
		self.statusUpdateHandler = statusUpdateHandler

		guard let statusUpdateHandler else {
			transport.setTransportStateHandler(nil)

			return
		}

		transport.setTransportStateHandler { state in
			switch state {
				case .setup: statusUpdateHandler(.setup)
				case .preparing: statusUpdateHandler(.preparing)
				case .ready: statusUpdateHandler(.ready)
				case .waiting(let error): statusUpdateHandler(.waiting(error))
				case .failed(let error): statusUpdateHandler(.failed(error))
				case .cancelled: statusUpdateHandler(.cancelled)
			}
		}
	}

	func cancel() { transport.cancelTransport() }
	func start(queue: DispatchQueue) { transport.startTransport(queue: queue) }

	func read(minimumLength: Int, maximumLength: Int) async throws -> Data {
		try await transport.readTransport(minimumLength: minimumLength,
										  maximumLength: maximumLength)
	}

	func write(data: Data) async throws {
		try await transport.writeTransport(data: data)
	}
}
