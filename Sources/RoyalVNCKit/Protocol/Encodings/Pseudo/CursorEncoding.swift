#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct CursorEncoding: VNCReceivablePseudoEncoding {
		/// The largest cursor this client will allocate for. See `decode`.
		static let maximumCursorLength = 4 * 1024 * 1024

		let encodingType = VNCPseudoEncodingType.cursor.rawValue
	}
}

extension VNCProtocol.CursorEncoding {
	func receive(_ rectangle: VNCProtocol.Rectangle,
				 framebuffer: VNCFramebuffer,
				 connection: NetworkConnectionReading,
				 logger: VNCLogger) async throws {
		let hotspot = rectangle.region.location
		let size = rectangle.region.size

        let width = Int(size.width)
        let height = Int(size.height)

		let bytesPerPixel = framebuffer.sourceProperties.bytesPerPixel
        let bytesPerRow = (width + 7) / 8

        let pixelsLength = width * height * bytesPerPixel

		guard pixelsLength > 0 else {
			framebuffer.updateCursor(.empty)

			return
		}

        let maskLength = bytesPerRow * height
        let totalLength = maskLength + pixelsLength

		// Cursor carries no length field: the client computes one from the
		// rectangle header's own 16-bit width and height. At the maximum those
		// multiply out to about seventeen gigabytes, and the client requests
		// this pseudo-encoding by default, so a server can send it unprompted.
		//
		// 4 MiB is a 1024x1024 cursor at four bytes a pixel, which is already
		// far larger than any pointer a system draws.
		guard totalLength <= Self.maximumCursorLength else {
			throw VNCError.protocol(.invalidData)
		}

		logger.logDebug("Receiving Cursor data")

		let data = try await connection.readBuffered(length: totalLength)

		logger.logDebug("Finished receiving Cursor data")

		var image = data.subdata(in: 0..<pixelsLength)
		var mask = data.subdata(in: pixelsLength..<pixelsLength + maskLength)

		let cursor = framebuffer.decodeCursor(image: &image,
											  mask: &mask,
											  size: size,
											  hotspot: hotspot)

		framebuffer.updateCursor(cursor)
	}
}
