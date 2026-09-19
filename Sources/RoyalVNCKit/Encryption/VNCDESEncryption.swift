#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@_implementationOnly import d3des

struct VNCDESEncryption {
	static func encrypt(data: Data,
						key: String) -> Data? {
		var data = data
		var paddedKey = paddedKey(key)

		let success = encrypt(data: &data,
							  paddedKey: &paddedKey)

		guard success else {
			return nil
		}

		return data
	}
}

private extension VNCDESEncryption {
	static func encrypt(data: inout Data,
						paddedKey: inout Data) -> Bool {
		let success = data.withUnsafeMutableBytes { encryptedDataPtr in
			guard let encryptedDataBytes = encryptedDataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
				return false
			}

			return paddedKey.withUnsafeMutableBytes { paddedKeyPtr in
				guard let paddedKeyBytes = paddedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
					return false
				}

				encrypt(dataBytes: encryptedDataBytes,
						paddedKeyBytes: paddedKeyBytes)

				return true
			}
		}

		return success
	}

	static func paddedKey(_ key: String) -> Data {
		let maxKeyLength = 8

		// RFC 6143 §7.2.2: the key is eight BYTES of the password, truncated or
		// null-padded. Bytes, not Characters.
		//
		// The previous version compared `key.count`, which counts grapheme
		// clusters, against an index into `key.withCString`, which walks UTF-8
		// bytes. For any password with a non-ASCII character in its first eight
		// bytes that was not merely inaccurate, it crashed: `withCString` yields
		// `CChar`, so a byte of 0xC3 arrives as -61, and `UInt8.init(-61)` traps.
		// Verified: "\u{00e9}123" terminated the process with SIGTRAP.
		let keyBytes = Array(key.utf8.prefix(maxKeyLength))

		var paddedKey = Data(count: maxKeyLength)

		for idx in 0..<maxKeyLength {
			paddedKey[idx] = idx < keyBytes.count ? keyBytes[idx] : 0
		}

		return paddedKey
	}

	static func encrypt(dataBytes: UnsafeMutablePointer<UInt8>,
						paddedKeyBytes: UnsafeMutablePointer<UInt8>) {
		let challengeSize = 16

		// `deskey` and `des` share a global schedule, so they have to be held
		// together. See `D3DESKeySchedule`.
		D3DESKeySchedule.withExclusiveUse {
			deskey(paddedKeyBytes, EN0)

			for challengeIdx in stride(from: 0, to: challengeSize, by: 8) {
				let bytesAtOffset = dataBytes.advanced(by: challengeIdx)

				des(bytesAtOffset, bytesAtOffset)
			}
		}
	}
}
