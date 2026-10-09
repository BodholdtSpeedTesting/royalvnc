#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol.ARDAuthentication {
	struct DiffieHellmanKeyAgreement {
		let publicKey: Data
		let privateKey: Data
		let secretKey: Data

		init?(prime: Data,
			  generator: Data,
			  peerKey: Data,
			  keyLength: Int) {
			guard keyLength > 0,
				  let privateKey = Self.generatePrivateKey(prime: prime) else {
				return nil
			}

			self.init(prime: prime,
					  generator: generator,
					  peerKey: peerKey,
					  keyLength: keyLength,
					  privateKey: privateKey)
		}

		/// The agreement for a private key the caller chose: the tests', to compare what the kit
		/// sends with noVNC's test of this security type.
		init?(prime: Data,
			  generator: Data,
			  peerKey: Data,
			  keyLength: Int,
			  privateKey: Data) {
			guard keyLength > 0,
				  !privateKey.isEmpty else {
				return nil
			}

			guard let publicKey = Self.computePublicKey(generator: generator,
														prime: prime,
														privateKey: privateKey,
														keyLength: keyLength),
				  !publicKey.isEmpty else {
				return nil
			}

			guard let secretKey = Self.computeSharedKey(prime: prime,
														peerKey: peerKey,
														privateKey: privateKey,
														keyLength: keyLength),
				  !secretKey.isEmpty else {
				return nil
			}

			self.publicKey = publicKey
			self.privateKey = privateKey
			self.secretKey = secretKey
		}
	}
}

private extension VNCProtocol.ARDAuthentication.DiffieHellmanKeyAgreement {
	/// A private key in 1 ... p - 1, as bytes.
	static func generatePrivateKey(prime: Data) -> Data? {
		let bigPrivKey = BigNum()

		guard let bigPrime = BigNum(data: prime) else {
			return nil
		}

		// Generate DH private key
		repeat {
			let randSuccess = bigPrivKey.rand(range: bigPrime)

			guard randSuccess else {
				return nil
			}
		} while bigPrivKey.isZero

		guard let privKey = bigPrivKey.bigEndianData(),
			  !privKey.isEmpty else {
			return nil
		}

		return privKey
	}

	static func computePublicKey(generator: Data,
								 prime: Data,
								 privateKey: Data,
								 keyLength: Int) -> Data? {
		let bigPubKey = BigNum()

		guard let bigPrime = BigNum(data: prime),
			  let bigGenerator = BigNum(data: generator),
			  let bigPrivKey = BigNum(data: privateKey) else {
			return nil
		}

		let modSuccess = BigNum.modExp(y: bigPubKey,
									   g: bigGenerator,
									   x: bigPrivKey,
									   p: bigPrime)

		guard modSuccess else {
			return nil
		}

		// rfbproto.rst, Diffie-Hellman Authentication (lines 1336-1374): the client sends its public
		// value as key-size bytes. A value below the prime can need fewer -- one in 256 has a leading
		// zero byte, and every one does where the prime itself has one -- so it is sent padded to
		// key-size, as noVNC sends it. Both keys used to be refused unless they took exactly
		// key-size bytes, the private key too, which is never sent: about one key agreement in 128
		// failed, and the connection with it, before anything was sent. A public value of zero, or
		// one that cannot fit, is still refused.
		guard let pubKey = bigPubKey.bigEndianData(),
			  !pubKey.isEmpty,
			  pubKey.count <= keyLength else {
			return nil
		}

		return Data(count: keyLength - pubKey.count) + pubKey
	}

	static func computeSharedKey(prime: Data,
								 peerKey: Data,
								 privateKey: Data,
								 keyLength: Int) -> Data? {
		guard let bigPrime = BigNum(data: prime),
			  let bigPrivKey = BigNum(data: privateKey),
			  let bigPeerKey = BigNum(data: peerKey) else {
			return nil
		}

		let bigSharedKey = BigNum()

		let modSuccess = BigNum.modExp(y: bigSharedKey,
									   g: bigPeerKey,
									   x: bigPrivKey,
									   p: bigPrime)

		guard modSuccess else {
			return nil
		}

		// The shared secret, like the public value, as key-size bytes, its leading zero bytes kept:
		// rfbproto.rst (lines 1355-1356) derives the AES key as the MD5 digest of the shared
		// secret, noVNC digests it padded to key-size (core/crypto/dh.js, line 53), and RFC 2631
		// 2.1.2 keeps a Diffie-Hellman secret's leading zeros "so that ZZ occupies as many octets
		// as p". The kit digested it without them: one secret in 256 has a leading zero byte, and
		// every one does where the prime has one, so one login in 256 -- and every one with such a
		// prime -- sent credentials encrypted with a key the server did not have. A secret of zero
		// is still refused.
		guard let sharedKey = bigSharedKey.bigEndianData(),
			  !sharedKey.isEmpty,
			  sharedKey.count <= keyLength else {
			return nil
		}

		return Data(count: keyLength - sharedKey.count) + sharedKey
	}
}
