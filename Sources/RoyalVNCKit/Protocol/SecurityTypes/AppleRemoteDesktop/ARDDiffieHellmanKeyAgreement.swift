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
			guard keyLength > 0 else {
				return nil
			}

			guard let keyPair = Self.generateKeyPair(generator: generator,
													 prime: prime,
													 keyLength: keyLength),
				  !keyPair.privateKey.isEmpty,
				  !keyPair.publicKey.isEmpty else {
				return nil
			}

			guard let secretKey = Self.computeSharedKey(prime: prime,
														peerKey: peerKey,
														privateKey: keyPair.privateKey),
				  !secretKey.isEmpty else {
				return nil
			}

			self.publicKey = keyPair.publicKey
			self.privateKey = keyPair.privateKey
			self.secretKey = secretKey
		}
	}
}

private extension VNCProtocol.ARDAuthentication.DiffieHellmanKeyAgreement {
	struct KeyPair {
		let publicKey: Data
		let privateKey: Data
	}

	static func generateKeyPair(generator: Data,
								prime: Data,
								keyLength: Int) -> KeyPair? {
		let bigPrivKey = BigNum()
		let bigPubKey = BigNum()

		guard let bigPrime = BigNum(data: prime),
			  let bigGenerator = BigNum(data: generator) else {
			return nil
		}

		// Generate DH private key
		repeat {
			let randSuccess = bigPrivKey.rand(range: bigPrime)

			guard randSuccess else {
				return nil
			}
		} while bigPrivKey.isZero

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
		guard let privKey = bigPrivKey.bigEndianData(),
			  let pubKey = bigPubKey.bigEndianData(),
			  !privKey.isEmpty,
			  !pubKey.isEmpty,
			  pubKey.count <= keyLength else {
			return nil
		}

		let keyPair = KeyPair(publicKey: Data(count: keyLength - pubKey.count) + pubKey,
							  privateKey: privKey)

		return keyPair
	}

	static func computeSharedKey(prime: Data,
								 peerKey: Data,
								 privateKey: Data) -> Data? {
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

		guard let sharedKey = bigSharedKey.bigEndianData() else {
			return nil
		}

		return sharedKey
	}
}
