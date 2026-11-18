#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol.UltraVNCMSLogonIIAuthentication {
	struct Authentication {
        let encryptedCredential: Data
        let publicKey: Data

        private init(encryptedCredential: Data,
                     publicKey: Data) {
            self.encryptedCredential = encryptedCredential
            self.publicKey = publicKey
        }

        init?(agreement: DiffieHellmanKeyAgreement,
              username: String,
              password: String) {
            let usernameLength = 256
            let passwordLength = 64

			let key = agreement.secretKey

			guard let encryptedUsername = Self.encrypt(string: username,
													   length: usernameLength,
													   key: key) else {
				return nil
			}

			guard let encryptedPassword = Self.encrypt(string: password,
													   length: passwordLength,
													   key: key) else {
				return nil
			}

            let credentialsLength = usernameLength + passwordLength
            let credentialsData = encryptedUsername + encryptedPassword

			guard credentialsData.count == credentialsLength else {
				return nil
			}

            self.encryptedCredential = credentialsData
            self.publicKey = agreement.publicKey
        }
	}
}

private extension VNCProtocol.UltraVNCMSLogonIIAuthentication.Authentication {
    static func cappedOrPaddedStringData(string: String,
                                         length: Int) -> Data? {
        guard var data = string.data(using: .utf8) else { return nil }

        if data.count > length {
            data = data[0..<length]
        } else {
            let requiredPadding = length - data.count

            guard requiredPadding > 0 else {
                return data
            }

            data.appendPadding(length: .init(requiredPadding))
        }

        guard data.count == length else {
            return nil
        }

        return data
    }

	/// `string`, capped or zero-padded to `length` bytes (a multiple of eight), encrypted as MS-Logon II sends each of its
	/// credential's fields: DES in CBC mode, the first block XORed with the key itself, each later one with the ciphertext
	/// before it, under the key as VNC gives it to DES (`DES.vncKey`). As d3des's deskey/des chain did, measured against it
	/// and against OpenSSL's DES-CBC (IV the key, the key's bits reversed): DESTests. No state is kept between calls, so two
	/// connections authenticating at once cannot re-key each other.
	static func encrypt(string: String,
						length: Int,
						key: Data) -> Data? {
		guard let stringData = Self.cappedOrPaddedStringData(string: string,
															 length: length),
			  stringData.count == length,
			  length % 8 == 0,
			  key.count == 8 else {
			return nil
		}

		let keyBytes = [UInt8](key)
		let desKey = DES.vncKey(keyBytes)
		let plain = [UInt8](stringData)

		var encrypted = [UInt8]()
		encrypted.reserveCapacity(length)

		var previous = keyBytes

		for offset in stride(from: 0, to: length, by: 8) {
			let block = zip(plain[offset..<offset + 8], previous).map { $0 ^ $1 }

			previous = DES.encryptBlock(block, key: desKey)
			encrypted += previous
		}

		return Data(encrypted)
	}
}

extension VNCProtocol.UltraVNCMSLogonIIAuthentication.Authentication {
	/// One of the credential's two fields, `string` capped or zero-padded to `length` bytes and encrypted under the key
	/// agreement's secret `key`: what `init?(agreement:username:password:)` sends, given a key a test can choose (the
	/// agreement's is random).
	static func encryptedField(_ string: String,
							   length: Int,
							   key: Data) -> Data? {
		encrypt(string: string, length: length, key: key)
	}
}
