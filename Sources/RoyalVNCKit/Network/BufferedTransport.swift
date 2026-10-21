#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch

/// Serves the kit's reads from what reads of a block brought back from a transport.
///
/// The decoders read a field at a time: an RRE subrectangle is five reads, and a
/// Hextile tile is its subencoding mask, its colours and its count and then two
/// for each subrectangle (RFC 6143 7.7.3, 7.7.4). Every one of them used to be a
/// read of the transport -- on Apple platforms an NWConnection receive and a
/// continuation resumed, about 8 to 50 microseconds each however many bytes were
/// already waiting -- and a desktop's wallpaper sent as one Hextile rectangle is
/// 100,000 to 460,000 subrectangles. Measured on a Mac viewer, GNOME's 2.8 MB
/// first frame took 14.8 to 21.3 seconds that way, where the socket connection
/// decoded it in 0.54 on Linux. Now a read of the transport asks for a block of
/// up to 64 KiB, and the reads after it are served from what it brought back
/// without leaving the caller's task until it runs out. The socket connection on
/// Linux and Windows came to the same answer first ("Reading" in
/// SocketNetworkConnection.swift); this gives it to every transport, supplied or
/// dialled, and under it the socket connection hands each of its blocks up whole.
///
/// A read of a block or more, with nothing waiting, goes straight to the
/// transport, as every read used to: there is no field to save a receive on, and
/// a single read that large -- a cursor image, ServerCutText's text, each read
/// whole -- would otherwise be copied through the buffer and leave a buffer that
/// size behind. A frame's payload is not such a read: Raw, Zlib, ZRLE (through
/// Zlib's) and Tight read theirs 16 KiB at a time (`RawEncoding`,
/// `ZlibEncoding.retrieveCompressedData`, `TightEncoding.readBuffered`), under a
/// block, so those are served from the buffer like any field.
///
/// A transport of its own rather than a part of `TransportNetworkConnection`, so
/// that whatever takes the stream over keeps the bytes already read from it:
/// VeNCrypt hands the live transport to the embedder to wrap in TLS, and what
/// was read ahead of the upgrade is the TLS layer's, in front of everything
/// after it.
///
/// A block is asked for with a minimum of one byte, never the read's own: a
/// transport asked for more than will ever come either waits for it or reports
/// the end in place of the bytes that did come. The bytes that came with the
/// end are handed on first and the end is the next read's to report, as
/// `NWConnection.read(minimumLength:maximumLength:keepingEndIn:)` does with
/// Network.framework's.
final class BufferedTransport: VNCTransport {
	/// The transport underneath.
	let base: any VNCTransport

	/// What reads of `base` brought back that no reader has taken yet.
	private let received = ReceivedBytes()

	init(_ base: any VNCTransport) {
		self.base = base
	}

	var isTransportReady: Bool { base.isTransportReady }
	var transportState: VNCTransportState { base.transportState }

	func setTransportStateHandler(_ handler: VNCTransportStateHandler?) {
		base.setTransportStateHandler(handler)
	}

	func startTransport(queue: DispatchQueue) { base.startTransport(queue: queue) }

	/// Drops what was read ahead, and whatever the transport hands back from now
	/// on, then cancels the transport.
	///
	/// The kit looks for a disconnect between messages, and a message can be
	/// megabytes, so its decoders read on after a cancel until a read fails. A
	/// read of an NWConnection fails at once after a cancel, as each field's read
	/// did when it was one; a block read ahead would otherwise go on being
	/// decoded, and drawn, for up to 64 KiB after the connection was ended. So
	/// would a block that a read already in flight brings back after the cancel
	/// -- an NWConnection completion already on its way, a `recv` that had
	/// returned -- were it kept: it is refused, and that read fails too, as a read
	/// whose answer came after the cancel. The buffer is closed before the
	/// transport is cancelled, so an answer that lands while the transport is
	/// being cancelled is refused as well.
	///
	/// Every read after the cancel goes to the transport, which fails it at
	/// once: an NWConnection, and the socket connection (Linux, Windows), whose
	/// cancel ends a read already waiting for the server as well
	/// (`SocketNetworkConnection.cancel()`).
	func cancelTransport() {
		received.close()
		base.cancelTransport()
	}

	func readTransport(minimumLength: Int, maximumLength: Int) async throws -> Data {
		let wanted = max(minimumLength, 1)

		if let ready = received.take(minimumLength: wanted, maximumLength: maximumLength) {
			return ready
		}

		if maximumLength >= ReceivedBytes.chunkSize, received.count == 0 {
			let block = try await readBlock(maximumLength: maximumLength)

			if block.count >= wanted, block.count <= maximumLength {
				// Handed straight back, so not through `received`: checked here
				// instead for an answer that came after the cancel.
				guard !received.isClosed else {
					throw VNCError.connection(.cancelled)
				}

				return block
			}

			guard received.append(block) else {
				throw VNCError.connection(.cancelled)
			}
		}

		while received.count < wanted {
			guard received.append(try await readBlock(maximumLength: ReceivedBytes.chunkSize)) else {
				throw VNCError.connection(.cancelled)
			}
		}

		guard let data = received.take(minimumLength: wanted,
									   maximumLength: maximumLength) else {
			// Emptied between the append and the take: cancelled meanwhile.
			throw received.isClosed ? VNCError.connection(.cancelled) : VNCError.protocol(.invalidData)
		}

		return data
	}

	func writeTransport(data: Data) async throws {
		try await base.writeTransport(data: data)
	}

	/// One read of `base`: whatever has arrived, from one byte up to `maximumLength`.
	private func readBlock(maximumLength: Int) async throws -> Data {
		let block = try await base.readTransport(minimumLength: 1,
												 maximumLength: maximumLength)

		// A transport that hands back nothing has broken its contract, and
		// asking it again would spin.
		guard !block.isEmpty else {
			throw VNCError.protocol(.invalidData)
		}

		return block
	}
}
