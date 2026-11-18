#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// DES (FIPS 46-3), for VNC Authentication and MS-Logon II's credential: in place of d3des.c, whose VNC changes carry a
// copyright and no licence grant, and whose key schedule was one global for the whole process.
//
// Written by Bodholdt Labs from the standard, not from any implementation: DES is a published algorithm, and the tables
// below are its permutation and substitution tables, transcribed from FIPS 46-3. Bits are handled MSB-first, one per
// `UInt8` (0 or 1), the order FIPS numbers them in, so that the tables read straight across from the specification.
// Speed does not matter here -- a few blocks per connection -- so it is written to be plainly correct; and it keeps no
// state between calls, so concurrent connections cannot disturb one another's keys.
//
// VNC's key: RFC 6143 §7.2.2's verified erratum 4951 has "then the bits of each byte of the key are reversed", and
// rfbproto.rst "The lowest bit of each byte is considered the first bit and the highest discarded as parity. This is the
// reverse order of most implementations of DES" -- `vncKey(_:)`. d3des applied that reversal inside its key schedule for
// every caller, MS-Logon II's too; so does this, at each call. Checked against d3des's own output, run as it shipped, and
// against OpenSSL's DES: DESTests.

enum DES {

    // MARK: - Public API

    /// Encrypt one 8-byte block under an 8-byte key. DES-ECB, no padding.
    static func encryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(block.count == 8 && key.count == 8)

        let subkeys = subkeys(from: key)
        let permuted = permute(bits(of: block), Self.ip)          // 64 bits

        var left = Array(permuted[0..<32])
        var right = Array(permuted[32..<64])

        for round in 0..<16 {
            let next = xor(left, feistel(right, subkeys[round]))
            left = right
            right = next
        }

        // The final block is R16 ++ L16 (the halves are not swapped back), then IP^-1.
        return bytes(of: permute(right + left, Self.fp))
    }

    /// Encrypt a whole message whose length is a multiple of eight, block by
    /// block in ECB. VNC's challenge is sixteen bytes, i.e. two blocks.
    static func encryptECB(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(data.count % 8 == 0 && key.count == 8)

        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            out += encryptBlock(Array(data[i..<i + 8]), key: key)
            i += 8
        }
        return out
    }

    // MARK: - Round function

    private static func feistel(_ right: [UInt8], _ subkey: [UInt8]) -> [UInt8] {
        let mixed = xor(permute(right, Self.e), subkey)          // 48 bits
        var substituted = [UInt8]()
        substituted.reserveCapacity(32)

        for box in 0..<8 {
            let base = box * 6
            // Outer bits (first, last) pick the row; the middle four pick the column.
            let row = Int(mixed[base]) << 1 | Int(mixed[base + 5])
            let col = Int(mixed[base + 1]) << 3 | Int(mixed[base + 2]) << 2
                    | Int(mixed[base + 3]) << 1 | Int(mixed[base + 4])
            let value = Self.sBoxes[box][row * 16 + col]         // a 4-bit value
            substituted.append(UInt8((value >> 3) & 1))
            substituted.append(UInt8((value >> 2) & 1))
            substituted.append(UInt8((value >> 1) & 1))
            substituted.append(UInt8(value & 1))
        }

        return permute(substituted, Self.p)                     // 32 bits
    }

    private static func subkeys(from key: [UInt8]) -> [[UInt8]] {
        let permuted = permute(bits(of: key), Self.pc1)         // 56 bits
        var c = Array(permuted[0..<28])
        var d = Array(permuted[28..<56])

        var result = [[UInt8]]()
        result.reserveCapacity(16)
        for round in 0..<16 {
            c = leftRotate(c, Self.shifts[round])
            d = leftRotate(d, Self.shifts[round])
            result.append(permute(c + d, Self.pc2))             // 48 bits
        }
        return result
    }

    // MARK: - Bit helpers

    /// MSB-first, one bit per element -- the order FIPS numbers bits in.
    private static func bits(of bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 8)
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                out.append((byte >> UInt8(shift)) & 1)
            }
        }
        return out
    }

    private static func bytes(of bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bits.count / 8)
        for (index, bit) in bits.enumerated() {
            out[index / 8] = (out[index / 8] << 1) | bit
        }
        return out
    }

    /// `output[i] = input[table[i] - 1]` -- FIPS tables are 1-based.
    private static func permute(_ input: [UInt8], _ table: [Int]) -> [UInt8] {
        table.map { input[$0 - 1] }
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        zip(a, b).map { $0 ^ $1 }
    }

    private static func leftRotate(_ a: [UInt8], _ n: Int) -> [UInt8] {
        Array(a[n...] + a[..<n])
    }

    // MARK: - Tables (FIPS 46-3)

    /// Initial permutation.
    private static let ip: [Int] = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
        62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
        61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
    ]

    /// Final permutation (the inverse of `ip`).
    private static let fp: [Int] = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
        38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
        34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
    ]

    /// Expansion (32 -> 48).
    private static let e: [Int] = [
        32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11,
        12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21,
        22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
    ]

    /// Permutation inside the round function (32 -> 32).
    private static let p: [Int] = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
        2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
    ]

    /// Permuted choice 1 (64 -> 56; the key's parity bits fall away here).
    private static let pc1: [Int] = [
        57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
        10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
        63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
        14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
    ]

    /// Permuted choice 2 (56 -> 48).
    private static let pc2: [Int] = [
        14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
        23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
        44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
    ]

    /// Left-rotation amount for C and D at each of the sixteen rounds.
    private static let shifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]

    /// The eight S-boxes, each a 4x16 table flattened row-major.
    private static let sBoxes: [[Int]] = [
        [ // S1
            14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
            0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
            4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
            15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
        ],
        [ // S2
            15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
            3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
            0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
            13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
        ],
        [ // S3
            10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
            13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
            13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
            1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
        ],
        [ // S4
            7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
            13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
            10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
            3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
        ],
        [ // S5
            2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
            14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
            4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
            11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
        ],
        [ // S6
            12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
            10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
            9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
            4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
        ],
        [ // S7
            4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
            13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
            1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
            6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
        ],
        [ // S8
            13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
            1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
            7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
            2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
        ],
    ]
}

extension DES {
	/// The eight-byte key `key` as VNC hands it to DES: each byte's bits reversed.
	static func vncKey(_ key: [UInt8]) -> [UInt8] {
		key.map { byte in
			var value = byte
			var reversed: UInt8 = 0

			for _ in 0..<8 {
				reversed = (reversed << 1) | (value & 1)
				value >>= 1
			}

			return reversed
		}
	}
}
