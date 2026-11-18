#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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
		// RFC 6143 §7.2.2: each eight bytes of the challenge encrypted independently (ECB), under the password's key.
		guard data.count % 8 == 0,
			  paddedKey.count == 8 else {
			return false
		}

		data = Data(DES.encryptECB([UInt8](data), key: DES.vncKey([UInt8](paddedKey))))

		return true
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
}
