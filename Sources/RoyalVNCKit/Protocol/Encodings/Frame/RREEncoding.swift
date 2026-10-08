#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct RREEncoding: VNCFrameEncoding {
		let encodingType = VNCFrameEncodingType.rre.rawValue
	}
}

extension VNCProtocol.RREEncoding {
	func decodeRectangle(_ rectangle: VNCProtocol.Rectangle,
						 framebuffer: VNCFramebuffer,
						 connection: NetworkConnectionReading,
						 logger: VNCLogger) async throws {
		logger.logDebug("Beginning to read RRE Encoding")

		let bytesPerPixel = framebuffer.sourceProperties.bytesPerPixel

		let numberOfSubRectangles = try await connection.readUInt32()
		var backgroundPixelValue = try await connection.read(length: bytesPerPixel)

		logger.logDebug("Received RRE Encoding number of sub rectangles: \(numberOfSubRectangles)")

		framebuffer.fill(region: rectangle.region,
						 withPixel: &backgroundPixelValue)

		for idx in 0..<numberOfSubRectangles {
			logger.logDebug("Receiving RRE Encoding Sub Rectangles \(idx + 1)/\(numberOfSubRectangles)")

			let subRectangle = try await SubRectangle.receive(bytesPerPixel: bytesPerPixel,
															  connection: connection)

			// RFC 6143 7.7.3: a sub-rectangle's x and y are "the coordinates of the subrectangle
			// relative to the top-left corner of the rectangle", and the sub-rectangles are a
			// partition of it, "rectangular subregions ... the union of which comprises the
			// original rectangular region" (rfbproto.rst, RRE Encoding, lines 3203-3215). One
			// that does not lie inside its rectangle is a server breaking the protocol, not an
			// element to skip: what it was meant to draw cannot be known, drawing it would paint
			// pixels the update never claimed, and the rest of the update is the same encoder's
			// work. So the update stops and the session ends with the error, as it does for a
			// rectangle outside the framebuffer (FramebufferUpdate.receive). The position used
			// to be a UInt16 sum, and a sub-rectangle at 0xFFFF trapped.
			guard let subRegion = rectangle.subregion(x: Int(subRectangle.xPosition),
													  y: Int(subRectangle.yPosition),
													  width: Int(subRectangle.width),
													  height: Int(subRectangle.height)) else {
				throw VNCError.protocol(.subrectangleOutOfBounds(encodingType: encodingType,
																 subrectangle: .init(x: subRectangle.xPosition,
																					 y: subRectangle.yPosition,
																					 width: subRectangle.width,
																					 height: subRectangle.height),
																 bounds: rectangle.region.size))
			}

			var foregroundPixelValue = subRectangle.pixelValue

			logger.logDebug("Received RRE Encoding Sub Rectangle \(idx + 1)/\(numberOfSubRectangles): \(subRectangle)")

			framebuffer.fill(region: subRegion,
							 withPixel: &foregroundPixelValue)
		}

		let region = rectangle.region

		framebuffer.didUpdate(region: region)
	}
}

private extension VNCProtocol.RREEncoding {
	struct SubRectangle {
		let pixelValue: Data

		let xPosition: UInt16
		let yPosition: UInt16

		let width: UInt16
		let height: UInt16
	}
}

private extension VNCProtocol.RREEncoding.SubRectangle {
	static func receive(bytesPerPixel: Int,
						connection: NetworkConnectionReading) async throws -> Self {
		let pixelValue = try await connection.read(length: bytesPerPixel)

		let xPosition = try await connection.readUInt16()
		let yPosition = try await connection.readUInt16()

		let width = try await connection.readUInt16()
		let height = try await connection.readUInt16()

		return .init(pixelValue: pixelValue,
					 xPosition: xPosition,
					 yPosition: yPosition,
					 width: width,
					 height: height)
	}
}
