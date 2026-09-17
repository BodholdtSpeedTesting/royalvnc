#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	/// The security type in an RFB 3.3 handshake, which the server picks alone.
	///
	/// RFC 6143 7.1.2: from 3.7 onwards the server offers a list and the client
	/// chooses one, but "version 3.3 the server decides the security type and
	/// sends a single word". The word is four bytes, not the one byte that
	/// prefixes the 3.7 list, so reading a 3.3 handshake with the 3.7 code path
	/// consumes the high byte of the type — which is zero for every type there
	/// is — and concludes that the server offered no security types at all.
	///
	/// A value of 0 means the connection failed, and is followed by a reason
	/// string. There is no negotiation: the client either supports what it was
	/// given or gives up.
	struct ServerChosenSecurityType {
		let value: UInt32

		fileprivate init(value: UInt32) {
			self.value = value
		}
	}
}

extension VNCProtocol.ServerChosenSecurityType {
	static func receive(connection: NetworkConnectionReading) async throws -> Self {
		let value = try await connection.readUInt32()

		return Self(value: value)
	}

	static func receiveFailureReason(connection: NetworkConnectionReading) async throws -> String {
		try await connection.readString(encoding: .utf8)
	}

	/// The type as this kit names it, or nil for one it does not implement.
	var securityType: VNCProtocol.SecurityType? {
		guard value <= UInt32(UInt8.max) else { return nil }

		return .init(rawValue: UInt8(value))
	}
}
