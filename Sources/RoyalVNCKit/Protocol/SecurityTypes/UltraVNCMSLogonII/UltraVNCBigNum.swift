#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol.UltraVNCMSLogonIIAuthentication.DiffieHellmanKeyAgreement {
	struct UltraVNCBigNum {
		static func dataToBigNum(_ data: Data) -> UInt64 {
			var result = UInt64(0)

			for idx in 0..<8 {
				result <<= 8
				result += .init(data[idx])
			}

			return result
		}

		static func bigNumToData(_ number: UInt64) -> Data {
			var data = Data(repeating: 0, count: 8)

			for idx in 0..<8 {
				let newValue = UInt8(0xff & (number >> (8 * (7 - idx))))

				data[idx] = newValue
			}

			return data
		}

		static func randomBigNum(max: UInt32) -> UInt64 {
			let num = UInt32.random(in: 0..<max)

			return .init(num)
		}

		/// Simple 64bit big integer arithmetic implementation
		/// (x + y) % m, works even if (x + y) > 64bit
		static func addM64(x: UInt64,
						   y: UInt64,
						   m: UInt64) -> UInt64 {
			let part = Int64(x + y < x
							 ? (-1 % .init(m) + 1) % .init(m)
							 : 0)

			let partU: UInt64 = numericCast(part)

			let result: UInt64 = (x + y) % m + partU

			return result
		}

		/// (x * y) % m
		///
		/// Russian-peasant multiplication, so that the intermediate product
		/// cannot overflow even when the modulus is large.
		static func mulM64(x: UInt64,
						   y: UInt64,
						   m: UInt64) -> UInt64 {
			var x = x
			var y = y % m
			var r = UInt64(0)

			while x > 0 {
				if x & 1 != 0 {
					r = addM64(x: r, y: y, m: m)
				}

				x >>= 1
				y = addM64(x: y, y: y, m: m)
			}

			return r
		}

		/// (b ^ e) % m
		static func powM64(b: UInt64,
						   e: UInt64,
						   m: UInt64) -> UInt64 {
			guard m > 1 else { return 0 }

			var b = b % m
			var e = e
			var r = UInt64(1)

			while e > 0 {
				if e & 1 != 0 {
					r = mulM64(x: r, y: b, m: m)
				}

				e >>= 1
				b = mulM64(x: b, y: b, m: m)
			}

			return r
		}
	}
}
