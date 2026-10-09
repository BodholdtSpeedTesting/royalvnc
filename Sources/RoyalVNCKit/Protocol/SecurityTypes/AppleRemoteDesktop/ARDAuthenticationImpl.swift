#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Security)
import Security
#endif

extension VNCProtocol.ARDAuthentication {
    struct Authentication {
        let cipherText: Data
        let publicKey: Data

        private init(cipherText: Data,
                     publicKey: Data) {
            self.cipherText = cipherText
            self.publicKey = publicKey
        }

        init?(agreement: DiffieHellmanKeyAgreement,
              username: String,
              password: String) {
            let credArraySize = Self.credentialsLength
            var creds = Data(count: credArraySize)

            let randomCredsDataSuccess = creds.withUnsafeMutableBytes {
                guard let credsBytes = $0.baseAddress else { return false }

#if canImport(Security)
				let randomStatus = SecRandomCopyBytes(kSecRandomDefault, credArraySize, credsBytes)

                guard randomStatus == errSecSuccess else { return false }
#else
				// TODO: Probably not secure
				for i in 0..<credArraySize {
					$0[i] = UInt8.random(in: 0...255)
				}
#endif

                return true
            }

            guard randomCredsDataSuccess else { return nil }

            self.init(agreement: agreement,
                      username: username,
                      password: password,
                      fill: creds)
        }

        /// The 128 bytes the credentials are written over (rfbproto.rst, Diffie-Hellman
        /// Authentication: each "padded with random data").
        static let credentialsLength = 128

        /// The credentials written over `fill` -- random bytes, except in the tests, which give
        /// noVNC's test vector's -- and encrypted.
        init?(agreement: DiffieHellmanKeyAgreement,
              username: String,
              password: String,
              fill: Data) {
            // Get MD5 hash of shared secret
			let secretHash = agreement.secretKey.md5Hash()

            // ciphertext: AES128(shared, username[64]:password[64])
            let credArraySize = Self.credentialsLength

            guard fill.count == credArraySize else { return nil }

            var creds = Data(fill)

			// Each field is capped to 63 UTF-8 bytes, so that the field and its NUL terminator fit
			// the 64-byte half it is written into. Capped by bytes, not by a character offset:
			// `username.index(startIndex, offsetBy: 63)` ran off the end of a string of fewer than
			// 63 characters (a multibyte field over 63 bytes trapped), and a 63-character slice of
			// multibyte characters was up to 189 bytes and overran the 128-byte block. rfbproto.rst's
			// Diffie-Hellman Authentication makes each field 64 bytes with its NUL; noVNC cuts each to
			// 63 bytes of UTF-8 (core/rfb.js _negotiateARDAuthAsync), as MS-Logon II already does.
			let maxLength = credArraySize / 2 - 1

			let usernameC = Array(Data(username.utf8).prefix(maxLength))
			let passwordC = Array(Data(password.utf8).prefix(maxLength))

			let cappedUsernameLength = usernameC.count
			let cappedPasswordLength = passwordC.count

			// Merge username and password into single array
			let fillCredsSuccess = creds.withUnsafeMutableBytes {
				guard let credsBytes = $0.baseAddress else { return false }

				let copyUsernameSuccess = usernameC.withUnsafeBytes { usernameCBytesPtr in
					guard let usernameCBytes = usernameCBytesPtr.baseAddress else { return false }

					credsBytes.copyMemory(from: usernameCBytes,
										  byteCount: cappedUsernameLength)

					return true
				}

				guard copyUsernameSuccess else { return false }

				let copyPasswordSuccess = passwordC.withUnsafeBytes { passwordCBytesPtr in
					guard let passwordCBytes = passwordCBytesPtr.baseAddress else { return false }

					let credsBytesStartingAtPassword = credsBytes.advanced(by: credArraySize / 2)

					credsBytesStartingAtPassword.copyMemory(from: passwordCBytes,
															byteCount: cappedPasswordLength)

					return true
				}

				guard copyPasswordSuccess else { return false }

				return true
			}

			guard fillCredsSuccess else { return nil }

			// Add null bytes to indicate end of c string
			creds[cappedUsernameLength] = 0
			creds[(credArraySize / 2) + cappedPasswordLength] = 0

			guard let cipherText = creds.aes128ECBEncrypted(withKey: secretHash) else {
				return nil
			}

            self.init(cipherText: cipherText,
                      publicKey: agreement.publicKey)
        }
    }
}
