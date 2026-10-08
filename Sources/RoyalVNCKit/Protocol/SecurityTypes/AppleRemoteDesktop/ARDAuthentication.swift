#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct ARDAuthentication: VNCSecurityType {
		static let authenticationType = VNCAuthenticationType.appleRemoteDesktop
		let authenticationType: VNCAuthenticationType = Self.authenticationType

		let generator: Data // Is actually UInt16 but our implementation requires Data, so...
		let keySize: UInt16
		let prime: Data
		let peerKey: Data

		fileprivate init?(generator: Data,
						  keySize: UInt16,
						  prime: Data,
						  peerKey: Data) {
			guard generator.count == 2 else {
				return nil
			}

			self.generator = generator
			self.keySize = keySize

			guard prime.count == keySize,
				  peerKey.count == keySize else {
				return nil
			}

			self.prime = prime
			self.peerKey = peerKey
		}
	}
}

extension VNCProtocol.ARDAuthentication {
	static func receive(connection: NetworkConnectionReading) async throws -> Self {
		let generator = try await connection.readBuffered(length: 2)
		let keySize = try await connection.readUInt16()
		let prime = try await connection.readBuffered(length: .init(keySize))
		let peerKey = try await connection.readBuffered(length: .init(keySize))

		// Before the user is asked for anything.
		try validateGroup(generator: generator,
						  keySize: keySize,
						  prime: prime,
						  peerKey: peerKey)

		guard let auth = Self(generator: generator,
							  keySize: keySize,
							  prime: prime,
							  peerKey: peerKey) else {
			throw VNCError.protocol(.invalidData)
		}

		return auth
	}

	func send(connection: NetworkConnectionWriting,
			  credential: VNCUsernamePasswordCredential) async throws {
		let authentication = try authenticate(credential: credential)

		let cipherText = authentication.cipherText
		let publicKey = authentication.publicKey

		try await Self.sendResponse(connection: connection,
									cipherText: cipherText,
									publicKey: publicKey)
	}
}

// MARK: - The group
extension VNCProtocol.ARDAuthentication {
	/// The key sizes, in bytes, a real group has: 64 to 1,024, 512 to 8,192 bits.
	///
	/// rfbproto.rst, Diffie-Hellman Authentication (lines 1336-1374): the server sends a U16
	/// generator, a U16 key-size, and a key-size-byte prime modulus and public value, and puts
	/// no bound on key-size. The smallest group RFC 2409, RFC 3526 or RFC 7919 defines is 768
	/// bits (RFC 2409's First Oakley Group) and the largest 8,192 (RFC 3526's and RFC 7919's), so
	/// a key outside 512 to 8,192 bits is no group anyone uses; noVNC's test of this security
	/// type uses 128 bytes. Measured on an Apple-silicon Mac, a release build: the key
	/// agreement takes 15 ms at 128 bytes, 0.75 s at 512 and 5.7 s at 1,024, about 7.6 times as
	/// long for each doubling -- roughly the cube of the size -- so at 65,535 bytes about two weeks.
	static let keySizes = 64...1024

	/// Throws `diffieHellmanGroupRefused` for parameters that cannot be a real group, before
	/// anything is computed with them.
	///
	/// A Diffie-Hellman prime above 2 is odd. The generator and the server's public value must
	/// lie in 2 ... p - 2: RFC 2631 2.1.5 checks a public value against [2, p-1], and p - 1 is
	/// excluded too, its square being 1, which leaves the shared secret 1 or p - 1 whatever the
	/// private key is. That rules out a prime of one, which made the private key's
	/// `repeat ... while isZero` loop spin for ever (a random number below one is always zero),
	/// and of zero, which trapped in CryptoSwift's `randomInteger(lessThan:)` precondition.
	///
	/// A server sending such parameters is breaking the protocol, and the handshake ends with
	/// the error -- there is no element to drop, the group being the whole of the exchange.
	static func validateGroup(generator: Data,
							  keySize: UInt16,
							  prime: Data,
							  peerKey: Data) throws {
		func refuse(_ reason: String) -> Error {
			VNCError.protocol(.diffieHellmanGroupRefused(reason: reason))
		}

		guard keySizes.contains(Int(keySize)) else {
			throw refuse("a key size of \(keySize) bytes, outside \(keySizes.lowerBound) to \(keySizes.upperBound)")
		}

		guard prime.count == Int(keySize),
			  peerKey.count == Int(keySize),
			  generator.count == 2 else {
			throw VNCError.protocol(.invalidData)
		}

		guard let lastByte = prime.last,
			  lastByte & 1 == 1 else {
			throw refuse("an even prime modulus")
		}

		guard let primeLessTwo = BigEndian.subtracting(2, from: BigEndian.magnitude(prime)) else {
			throw refuse("a prime modulus of one")
		}

		func liesInside(_ value: Data) -> Bool {
			let magnitude = BigEndian.magnitude(value)

			return !BigEndian.isLess(magnitude, [2]) && !BigEndian.isLess(primeLessTwo, magnitude)
		}

		guard liesInside(generator) else {
			throw refuse("a generator outside 2 to the prime less two")
		}

		guard liesInside(peerKey) else {
			throw refuse("a public value outside 2 to the prime less two")
		}
	}

	/// Unsigned integers as big-endian bytes, as the wire carries them.
	private enum BigEndian {
		/// The value's bytes, its leading zeros dropped.
		static func magnitude(_ value: Data) -> [UInt8] {
			Array(value.drop(while: { $0 == 0 }))
		}

		/// Whether one magnitude is less than another.
		static func isLess(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
			lhs.count != rhs.count
				? lhs.count < rhs.count
				: lhs.lexicographicallyPrecedes(rhs)
		}

		/// A magnitude less a small number, or nil where that is below zero.
		static func subtracting(_ small: UInt8, from value: [UInt8]) -> [UInt8]? {
			var result = value
			var borrow = Int(small)
			var index = result.count - 1

			while borrow > 0 {
				guard index >= 0 else {
					return nil
				}

				let digit = Int(result[index]) - borrow

				result[index] = UInt8((digit + 256) % 256)
				borrow = digit < 0 ? 1 : 0
				index -= 1
			}

			return Array(result.drop(while: { $0 == 0 }))
		}
	}
}

private extension VNCProtocol.ARDAuthentication {
	static func sendResponse(connection: NetworkConnectionWriting,
							 cipherText: Data,
							 publicKey: Data) async throws {
		try await connection.write(data: cipherText)
		try await connection.write(data: publicKey)
	}

	func authenticate(credential: VNCUsernamePasswordCredential) throws -> Authentication {
		guard let agreement = DiffieHellmanKeyAgreement(prime: prime,
														generator: generator,
														peerKey: peerKey,
														keyLength: .init(keySize)),
			  !agreement.publicKey.isEmpty,
			  !agreement.privateKey.isEmpty,
			  !agreement.secretKey.isEmpty else {
			throw VNCError.authentication(.ardAuthenticationFailed)
		}

		guard let authentication = Authentication(agreement: agreement,
												  username: credential.username,
												  password: credential.password),
			  !authentication.publicKey.isEmpty,
			  !authentication.cipherText.isEmpty else {
			throw VNCError.authentication(.ardAuthenticationFailed)
		}

		return authentication
	}
}
