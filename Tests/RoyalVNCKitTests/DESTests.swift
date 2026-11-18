// DES (DES.swift), which replaced d3des.c: the standard's known answer; VNC Authentication's response and MS-Logon II's
// credential fields, each as d3des made them -- recorded by running the kit's VNCDESEncryption and MS-Logon II encryption
// at 0ba4b23, d3des still in it, and checked then against OpenSSL 3.6.4's DES (ECB, and CBC with the key as IV, each
// under the key with its bytes' bits reversed: 43 of 43) -- and that concurrent use keeps each caller's key, which
// d3des's one global key schedule did not without a lock.

import Foundation
import Dispatch
import XCTest
@testable import RoyalVNCKit

final class DESTests: XCTestCase {
	private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

	private static func bytes(_ hex: String) -> [UInt8] {
		var out = [UInt8]()
		var index = hex.startIndex

		while index < hex.endIndex {
			let next = hex.index(index, offsetBy: 2)
			out.append(UInt8(hex[index..<next], radix: 16)!)
			index = next
		}

		return out
	}

	/// The challenges the VNC vectors were recorded with, by index.
	private static let challenges: [Data] = [
		Data(0..<16),
		Data(repeating: 0xff, count: 16),
		Data(repeating: 0, count: 16),
		Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }),
	]

	/// The MS-Logon II secret keys the credential vectors were recorded with, by index.
	private static let keys: [Data] = [Data(0..<8), Data(repeating: 0xa5, count: 8), Data([0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78])]

	/// (password, challenge index, response) as d3des gave them.
	private static let vncVectors: [(String, Int, String)] = [
		("", 0, "491e890de9ace932838a49792f2213f3"),
		("", 1, "355550b2150e2451355550b2150e2451"),
		("", 2, "8ca64de9c1b123a78ca64de9c1b123a7"),
		("", 3, "82eb9ea7f7d5386f5ab260e236f76637"),
		("\u{61}", 0, "449407fb6f71bd517aca76866568a4e2"),
		("\u{61}", 1, "1a6448e0ea6e98cf1a6448e0ea6e98cf"),
		("\u{61}", 2, "79c330799acb6e9579c330799acb6e95"),
		("\u{61}", 3, "c26d92f6d058d5f8557f2c7124033b63"),
		("\u{70}\u{61}\u{73}\u{73}\u{77}\u{6f}\u{72}\u{64}", 0, "b866924125c8eebb9debc1db61c538e2"),
		("\u{70}\u{61}\u{73}\u{73}\u{77}\u{6f}\u{72}\u{64}", 1, "304754b2dbcfd942304754b2dbcfd942"),
		("\u{70}\u{61}\u{73}\u{73}\u{77}\u{6f}\u{72}\u{64}", 2, "ff97502e9422f089ff97502e9422f089"),
		("\u{70}\u{61}\u{73}\u{73}\u{77}\u{6f}\u{72}\u{64}", 3, "fe94010b7f74f7991c65a6cb114fd45a"),
		("\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{61}\u{62}\u{63}", 0, "83dd2b4dbd04367f28578fdd5b142740"),
		("\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{61}\u{62}\u{63}", 1, "cfde517752975f09cfde517752975f09"),
		("\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{61}\u{62}\u{63}", 2, "d29f6e7f0456f8ded29f6e7f0456f8de"),
		("\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{61}\u{62}\u{63}", 3, "2b202235569cf619fe21e5e93239565b"),
		("\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 0, "7d13fc5643ca0c048e71796fe629ecf3"),
		("\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 1, "b441fcdbcbb9ce19b441fcdbcbb9ce19"),
		("\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 2, "3fd0d5bb36a9a37c3fd0d5bb36a9a37c"),
		("\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 3, "65ca7751530d9ad67b48b33af4ae1ea8"),
		("\u{1f600}\u{78}", 0, "561ad12e47670c874e22f22950e66643"),
		("\u{1f600}\u{78}", 1, "879f4e780b384690879f4e780b384690"),
		("\u{1f600}\u{78}", 2, "7b25510a3f58cfa77b25510a3f58cfa7"),
		("\u{1f600}\u{78}", 3, "c3dc14728fae3d9e0c8b0304a1f3016e"),
		("\u{7f}\u{1}\u{7e}\u{20}", 0, "3fa2b17cea6e557754946fe6556c85b2"),
		("\u{7f}\u{1}\u{7e}\u{20}", 1, "35f1ab2d2ea3babc35f1ab2d2ea3babc"),
		("\u{7f}\u{1}\u{7e}\u{20}", 2, "f68d75ac491cde60f68d75ac491cde60"),
		("\u{7f}\u{1}\u{7e}\u{20}", 3, "e15143113d659dbb5afa14dd85102423")
	]

	/// (key index, field, field length, encrypted field) as d3des's deskey/des chain gave them.
	private static let msLogonVectors: [(Int, String, Int, String)] = [
		(0, "\u{75}\u{73}\u{65}\u{72}", 256, "f90ccdd054bbc545a7f7fc063b83e2019f2dbf4ceb829e4eda12486f8f2545a1e9de066370d6247e48ab44aae54f6324dd68bda415dfb89a4aa16226f4cce9528dec1ae0b8e2f9f60a5512c472a2ad5489cab9d6c31b98d680e32648d7dbb276a88494370c5807d8482b5cf946350426d20a4480c8ae2a4c7fdbf27f54a42adfac468b63e7c00aa0edeee98e43747c218201e7829129d7d8c284c64720c565c8c14a25bf55f7fc020663b7d939f09e975464a1d66b442bebe60576f2af1203d748ce4681269193121040c75144626c629c11b0244a9ed0de911bfe528fb969f596b2db9622baa9d8c4d0e3ec78bea05abeb1a41f4c7b5084d1ffe0a9e0d709be"),
		(0, "\u{41}\u{64}\u{6d}\u{69}\u{6e}\u{69}\u{73}\u{74}\u{72}\u{61}\u{74}\u{6f}\u{72}", 256, "dd0f52b6a179674bb1329e7bc1287a7b42d9307fa50fc3e169e28b5b802912d7b5973b5fb1843ac7c268093f7126f656fd628f00021bde931fd5291448346449ed7292846da8f53eb341a759f8b228a7cf86d6b913686e6660d4f49db0a3b8e6a0c3dc50f96f04d5acbe7525ed7d905a74024d507d9973b9906b023bd012442a03250b05674ed325b31e1aee1336c57ed84eeee2a96663c62cf8c94cf41077e68e549d16f5b6062313a5cfa7d9f385864586a1e4a4254645e83c29d605cc349bedd59fc12e332a0325daf30d1f527ff9ee2d2d519a19f285f2698ddf3141616c198297362f8e71869c642620f8bda0b12b7db0708b5f0caa6ee30b0bdce583b2"),
		(0, "", 64, "9695de3b054c329b92e3b9ebecf3c7e20998f6978945efd05dd86f2a90d457043f02e3d39551a078f33cfc7b048c7f876b7aeef4bc2d5cba82ca574964b8df0e"),
		(0, "\u{70}\u{77}", 64, "9ab7da5fbc83751cf31246bf55a913cea817b11aac72d2b8ad74ec98ce25634f417c1b68c4d4176bfe6b01f330790b5262da72555696ddc9c7dd47d8f9d5050d"),
		(0, "\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 64, "47c6acf04c2e63682639230aa8808ff32e55638fca3521d19b1fe4116111f99e30dbdf34426f5da3ad66d5b063df6b61d449ddddde1fe77be71268a38ed75f38"),
		(1, "\u{75}\u{73}\u{65}\u{72}", 256, "4a5ecc9db975c22f8ac3c51d2d645006c175c2b109b1705e6d216be0278e6d14a500b892e52ce1ffc61b000e0a28417605fb0e502805e5d5c1c483976111de62307e3f526e0b8f120ec26b6f821cae43c10de6d628293eab565c8eaf3b75068c5c30b077300833d18efabd017ac7946d2882f93de38d0970d3a55b979215ee7d9bc73810def2705f01795c71b26181e02de43d6062567a10752e9d404d3a99bb60d28056ff65b9398add0d8003079d129490e58a97d437f10f7b4409ac7edacd7cb76fd008916500d65bd4a0d977625439e6ac67659b3af7a86514232363969e75456098fe8e6a9fc2f75a03ddf6278829f9e7f308e07449121d36c2f3de3036"),
		(1, "\u{41}\u{64}\u{6d}\u{69}\u{6e}\u{69}\u{73}\u{74}\u{72}\u{61}\u{74}\u{6f}\u{72}", 256, "bd3a7985ed0da93d10fcf1d022c500beb1ceb3fd828e0cc3ca7c91a5aca0616301a08c5401f168044298fa0707e8ac9285bfb376aeb9d7d30e9b259047787a0867e3bff6eb164dd7470e6d776320097a4f345787e90785ab759348f86122c240fa44746ea8de030cf719e9f0cfaefb2ea66a8c5f5f5d95a0310698e6df0b918efcb65c0f72e15cddacd45b1e31c3ac8a7e8ea92f3b1c4c9365800d52496030d7fa5788a2924c2e3b7b9aa7d969a73f976e0acd8b5c63deef76bc91e4f074007a41da44c49cd2ad8517f2602671231ba41e15f58bb09c87d3fb1c9a3cad10614792d0135dc1502dcbc5a4404a3043929f9bc70ff3345ec8f653d11e1b12e5ae54"),
		(1, "", 64, "06fc7fde1c8389e7b065471b5e48351dcc0fe0936f8e80bc92b335da20c3df7cefe270369c1933e593b53c66acf217f873d006070a00cb7779a6330794a17e30"),
		(1, "\u{70}\u{77}", 64, "23f7b97183e84afd40644b98fe75419977099a2d47150a4875d83488744a5c305422f34a40bd0a72aff6b46c9353eff6d16aafa0dc223a550b9d2785d19419af"),
		(1, "\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 64, "09516e03bb463e296317a21e99e11f46f45b25841c3152250d73f4c3f4817c9a418662335459276eb9e3ba20560c81745f3ce7e7e58b714a5ce665a42b83e2c7"),
		(2, "\u{75}\u{73}\u{65}\u{72}", 256, "a969a5c7c35c4162280d1d2113cb2ba075c1ab72c12f77c1c58644654ebc6b7721962c373cb3bc7cd1aaa0874048b045611f5902a23ac796eb22abdc40757339639484d8d3d115dd784536c1b50a42ac429f47988cd0ffae10f7e47ae70ad11c30ccf8b6d7853e9eeaa28c314a87223923c97b91690ca989953e60dccdeb6d8615d4727914acd44b66d6e564504244b8726c994ba409a5b23f5685b3619fd749eede81ee2df1e11e764b9f9bdbd0d977fdafbadc746c52a72ecf0629395aecd8e6604ed4bf9c9b313b73ffc98f8500129d2031eea276f5edac26f7dd96460a4c2ba2c35fd88ab7156f4e27b1ada9ff1e81a2a17655a9e7e460dcd56b30e8bdb6"),
		(2, "\u{41}\u{64}\u{6d}\u{69}\u{6e}\u{69}\u{73}\u{74}\u{72}\u{61}\u{74}\u{6f}\u{72}", 256, "877f0e6e9e7179509d875bc9d751b0490d4bb6f68d6065eda1a888e3ee3bd4f294d79cc7657fc9a3ad2aa8875c02b91b8b1097610653c43757e967210b837445ce4cedaf84f6bb6ee2d655be8c30577c4392ccf33d98e4c0cbc2fb87f9c1053edc9058eb76643050b0728352172618c56fdc088c571ed7b9f02af0f8466530c3378faee0388889396037690b472fa5dad89e4e0d9825a1979869d381a8c2c0d425e3e1b412e6f88adc209b3a09a3424b7cc3fb839d949dad7a921b45a93e5d6288b142a022266417c9efc7b275a1d8e432a0ccd3e7320bd8d5f064cc4a1546694ef62e671aa952191559822ea7193540b020ee4642d82eb0d50e46cbca049f7c"),
		(2, "", 64, "f5b9a16b5ed3acfe7af7695bb129984fcdbef20940f8766b29899f8482aed4ada54006499e5b6f65e01c4b699feb45d53a74a4341f9210e2e1a08067df824569"),
		(2, "\u{70}\u{77}", 64, "4cfdcfe003bfc9ddf0fd6d8cafa5ffaf260e224191c25f5429db01f04d9ad8f507e5dfc9afb11c28934a56c7199d2b5d9152857efb737f3fd0fa6cbea716f61b"),
		(2, "\u{70}\u{e4}\u{73}\u{73}\u{77}\u{f6}\u{72}\u{64}", 64, "0c0f4457e0cabab3c9c8b890305a6f90a021b81030d609a50d8685f13c812f9b06673709c9aec11b2fac50132287ec298b98c1be0a112a17a0c96729d1c8f7ed")
	]

	func testTheStandardsKnownAnswer() {
		// Key 133457799BBCDFF1, plaintext 0123456789ABCDEF: 85E813540F0AB405 (OpenSSL's DES-ECB agrees).
		XCTAssertEqual(Self.hex(DES.encryptBlock(Self.bytes("0123456789abcdef"), key: Self.bytes("133457799bbcdff1"))),
					   "85e813540f0ab405")
	}

	func testVNCsKeyHasEachBytesBitsReversed() {
		XCTAssertEqual(DES.vncKey([0x01, 0x80, 0x0f, 0xf0, 0x00, 0xff, 0x61, 0xc3]),
					   [0x80, 0x01, 0xf0, 0x0f, 0x00, 0xff, 0x86, 0xc3])
	}

	func testVNCAuthenticationsResponseIsD3DESs() {
		for (password, challenge, response) in Self.vncVectors {
			let made = VNCDESEncryption.encrypt(data: Self.challenges[challenge], key: password)

			XCTAssertEqual(made.map { Self.hex([UInt8]($0)) }, response,
						   "password \(password.debugDescription), challenge \(challenge)")
		}
	}

	func testMSLogonIIsCredentialFieldsAreD3DESs() {
		for (key, field, length, encrypted) in Self.msLogonVectors {
			let made = VNCProtocol.UltraVNCMSLogonIIAuthentication.Authentication.encryptedField(field, length: length,
																								 key: Self.keys[key])

			XCTAssertEqual(made.map { Self.hex([UInt8]($0)) }, encrypted,
						   "key \(key), field \(field.debugDescription), \(length) bytes")
		}
	}

	func testCallersAtOnceEachKeepTheirKey() {
		// Eight threads, each its own password, 200 responses each: every one as made alone. With d3des's one global key
		// schedule and no lock, a deskey on one thread between another's deskey and des gave that one the wrong key.
		let passwords = (0..<8).map { "key\($0)\($0)\($0)" }
		let alone = passwords.map { VNCDESEncryption.encrypt(data: Self.challenges[3], key: $0) }
		let wrong = Counter()

		DispatchQueue.concurrentPerform(iterations: passwords.count) { index in
			for _ in 0..<200 where VNCDESEncryption.encrypt(data: Self.challenges[3], key: passwords[index]) != alone[index] {
				wrong.add()
			}
		}

		XCTAssertEqual(wrong.value, 0, "responses made with another caller's key")
	}

	private final class Counter: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0

		var value: Int {
			lock.lock()
			defer { lock.unlock() }
			return count
		}

		func add() {
			lock.lock()
			count += 1
			lock.unlock()
		}
	}
}
