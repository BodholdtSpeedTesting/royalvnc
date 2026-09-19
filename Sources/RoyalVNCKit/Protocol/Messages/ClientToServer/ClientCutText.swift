#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct ClientCutText: VNCSendableMessage {
		let messageType: UInt8 = 6

		let text: String
	}
}

extension VNCProtocol.ClientCutText {
	var data: Data {
		var latin1TextData = Self.latin1(text)
		var textLength = latin1TextData.count

		if textLength > UInt32.max {
			textLength = .init(UInt32.max)
			latin1TextData = .init(latin1TextData.subdata(in: 0..<textLength))
		}

		let length = 8 + textLength

		var data = Data(capacity: length)

		data.append(messageType)
		data.appendPadding(length: 3)

		data.append(UInt32(textLength), bigEndian: true)
		data.append(contentsOf: latin1TextData)

		guard data.count == length else {
			fatalError("VNCProtocol.ClientCutText data.count (\(data.count)) != \(length)")
		}

		return data
	}

	func send(connection: NetworkConnectionWriting) async throws {
		try await connection.write(data: data)
	}
}

extension VNCProtocol.ClientCutText {
	/// The clipboard as ISO 8859-1 bytes, never as nothing.
	///
	/// RFC 6143 7.5.6 says this field is Latin-1 and says nothing about text
	/// that will not fit in it. `String.data(using: .isoLatin1)` answers that
	/// question by returning nil for the whole string, and the caller here used
	/// to turn nil into an empty `Data` — so a clipboard containing one
	/// character outside Latin-1 was sent as a well-formed message of length
	/// zero, and the remote machine's clipboard was silently emptied.
	///
	/// That is not a rare case on a Mac. macOS turns a typed apostrophe into
	/// U+2019 and a double hyphen into an em dash by default, so ordinary
	/// English prose is routinely outside Latin-1 — "don't" copied from any text
	/// field usually is.
	///
	/// So each scalar is mapped rather than the string being converted:
	///
	///   * anything Latin-1 already holds goes through unchanged;
	///   * the punctuation macOS substitutes for typed ASCII goes back to what
	///     was typed, which is lossless in the only sense a user cares about;
	///   * a newline is normalised to CRLF, because the other end is usually
	///     Windows and a bare LF pastes as one long line there;
	///   * everything else becomes "?", one per scalar.
	///
	/// A "?" is a poor substitute for 日本語, and it is a much better answer than
	/// an empty clipboard, because it is visible. The protocol cannot carry it:
	/// the fix for that is the Extended Clipboard pseudo-encoding, which is
	/// UTF-8 and which this kit does not implement.
	static func latin1(_ text: String) -> Data {
		var bytes = [UInt8]()
		bytes.reserveCapacity(text.unicodeScalars.count)

		for scalar in text.unicodeScalars {
			switch scalar {
			// Smart punctuation, back to the keys that produced it.
			case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2039}", "\u{203A}":
				bytes.append(UInt8(ascii: "'"))
			case "\u{201C}", "\u{201D}", "\u{201E}":
				bytes.append(UInt8(ascii: "\""))
			case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}":
				bytes.append(UInt8(ascii: "-"))
			case "\u{2026}":
				bytes.append(contentsOf: [UInt8(ascii: "."), UInt8(ascii: "."), UInt8(ascii: ".")])
			case "\u{2028}", "\u{2029}":
				bytes.append(contentsOf: [0x0D, 0x0A])

			// Line endings. A lone LF and a lone CR both become CRLF, and an
			// existing CRLF is left alone by the CR case doing nothing until its
			// LF arrives.
			case "\u{000A}":
				if bytes.last != 0x0D { bytes.append(0x0D) }
				bytes.append(0x0A)
			case "\u{000D}":
				bytes.append(0x0D)

			default:
				if scalar.value <= 0xFF {
					bytes.append(UInt8(scalar.value))
				} else {
					bytes.append(UInt8(ascii: "?"))
				}
			}
		}

		// A trailing lone CR, from text ending in one, would leave the line
		// unterminated at the far end.
		if bytes.last == 0x0D { bytes.append(0x0A) }

		return Data(bytes)
	}
}
