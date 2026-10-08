#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

final class DataStream {
	let data: Data
	private(set) var offset = 0

	private let dataLength: Int

	init(data: Data) {
		self.data = data
		self.dataLength = data.count
	}
}

extension DataStream: AnyStream {
	func read(length: Int) throws -> Data {
		let currentOffset = self.offset
		let newOffset = currentOffset + length

		// The data is what a server's zlib stream inflated to -- ZRLE's tiles -- so its length is the
		// server's to choose. This check was compiled into debug builds only: a release build
		// asked for bytes past the end trapped in `subdata(in:)`. A stream that ends before its
		// tiles do is a server breaking the protocol, and ends the session with the error, as it
		// always did in a debug build.
		guard length >= 0,
			  newOffset <= dataLength else {
			throw VNCError.protocol(.noData)
		}

		let subData = data.subdata(in: currentOffset..<newOffset)

		self.offset = newOffset

		return subData
	}
}
