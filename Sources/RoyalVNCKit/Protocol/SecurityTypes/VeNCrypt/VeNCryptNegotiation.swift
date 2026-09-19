#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	/// The VeNCrypt handshake, up to the point where a subtype is settled.
	///
	/// rfbproto.rst, "VeNCrypt". Security type 19 is not an authentication
	/// method: it is a version exchange followed by a second list of security
	/// types, from which the client chooses again.
	///
	/// THE TRAP IN THIS HANDSHAKE, and the reason the two acknowledgements are
	/// read by separate named methods below: **they have opposite polarity.**
	/// The specification says of the first, "Non-zero value means failure...
	/// Zero value means success", and of the second, "Non-one value means
	/// failure... One value means success". A single `readAck` helper used for
	/// both would be correct for one server and silently wrong for the other,
	/// and the failure would present as a desynchronised stream rather than as
	/// a rejected connection.
	enum VeNCrypt {
		/// The highest version this client speaks.
		///
		/// 0.2. The specification describes only this version: "Although two
		/// versions exist, 0.1 and 0.2, this document describes only newer
		/// version 0.2." A 0.1 server is therefore not something this client can
		/// implement from an approved source, and it says so rather than
		/// guessing.
		static let major: UInt8 = 0
		static let minor: UInt8 = 2

		struct Version: Equatable, CustomStringConvertible {
			let major: UInt8
			let minor: UInt8

			var description: String { "\(major).\(minor)" }
		}

		enum Failure: Swift.Error, CustomStringConvertible {
			case versionRejected(ours: Version, theirs: Version)
			case serverRefusedVersion(ack: UInt8)
			case noSubtypesOffered
			case subtypeRejected(ack: UInt8)
			case unsupportedVersion(Version)

			var description: String {
				switch self {
					case .versionRejected(let ours, let theirs):
						return """
							The server offered VeNCrypt \(theirs) and this client \
							speaks \(ours); there is no version in common.
							"""
					case .serverRefusedVersion(let ack):
						return """
							The server refused the VeNCrypt version this client \
							offered (it answered \(ack); zero would have meant \
							accepted).
							"""
					case .noSubtypesOffered:
						return "The server offered no VeNCrypt subtypes at all."
					case .subtypeRejected(let ack):
						return """
							The server refused the VeNCrypt subtype this client \
							chose (it answered \(ack); one would have meant \
							accepted).
							"""
					case .unsupportedVersion(let version):
						return """
							The server speaks VeNCrypt \(version). Only 0.2 is \
							described by the protocol document this client is \
							written from.
							"""
				}
			}
		}

		/// Exchanges versions and returns the one agreed.
		static func negotiateVersion(connection: NetworkConnection,
									 logger: VNCLogger) async throws -> Version {
			let theirs = Version(major: try await connection.readUInt8(),
								 minor: try await connection.readUInt8())

			logger.logDebug("VeNCrypt: server offers version \(theirs)")

			// "Then client sends back the highest VeNCrypt version it can
			// support, up to version that it received from the server."
			let ours = Version(major: major, minor: minor)

			guard theirs.major == ours.major, theirs.minor >= ours.minor else {
				// Answering with a version the server did not offer would be a
				// protocol violation, and answering 0.1 would mean implementing
				// a version no approved source describes.
				try await connection.write(value: 0)
				try await connection.write(value: 0)

				throw theirs.major == 0 && theirs.minor < ours.minor
					? Failure.unsupportedVersion(theirs)
					: Failure.versionRejected(ours: ours, theirs: theirs)
			}

			try await connection.write(value: ours.major)
			try await connection.write(value: ours.minor)

			logger.logDebug("VeNCrypt: agreed version \(ours)")

			return ours
		}

		/// Reads the acknowledgement that follows the version exchange.
		///
		/// **Zero means success here.** See the note on this type.
		static func receiveVersionAck(connection: NetworkConnection,
									  logger: VNCLogger) async throws {
			let ack = try await connection.readUInt8()

			logger.logDebug("VeNCrypt: version ack \(ack) (zero means accepted)")

			guard ack == 0 else { throw Failure.serverRefusedVersion(ack: ack) }
		}

		/// The subtypes the server is offering.
		static func receiveSubtypes(connection: NetworkConnection,
									logger: VNCLogger) async throws -> [UInt32] {
			let count = try await connection.readUInt8()

			guard count > 0 else { throw Failure.noSubtypesOffered }

			var subtypes = [UInt32]()
			subtypes.reserveCapacity(Int(count))

			for _ in 0..<count {
				subtypes.append(try await connection.readUInt32())
			}

			logger.logDebug("VeNCrypt: server offers subtypes \(subtypes)")

			return subtypes
		}

		/// Tells the server which subtype the client will use.
		static func send(subtype: UInt32,
						 connection: NetworkConnection,
						 logger: VNCLogger) async throws {
			var data = Data(capacity: 4)
			data.append(subtype, bigEndian: true)

			try await connection.write(data: data)

			logger.logDebug("VeNCrypt: chose subtype \(subtype)")
		}

		/// Reads the acknowledgement that follows the subtype choice.
		///
		/// **One means success here** — the opposite of the version ack above.
		/// Only sent for the TLS and X509 subtypes: "For TLS and X509 subtypes,
		/// the server then sends a one byte response".
		static func receiveSubtypeAck(connection: NetworkConnection,
									  logger: VNCLogger) async throws {
			let ack = try await connection.readUInt8()

			logger.logDebug("VeNCrypt: subtype ack \(ack) (one means accepted)")

			guard ack == 1 else { throw Failure.subtypeRejected(ack: ack) }
		}
	}
}
