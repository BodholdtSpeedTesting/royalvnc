#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct CoRREEncoding: VNCFrameEncoding {
		let encodingType = VNCFrameEncodingType.coRRE.rawValue
	}
}

extension VNCProtocol.CoRREEncoding {
	func decodeRectangle(_ rectangle: VNCProtocol.Rectangle,
						 framebuffer: VNCFramebuffer,
						 connection: NetworkConnectionReading,
						 logger: VNCLogger) async throws {
		logger.logDebug("Beginning to read CoRRE Encoding")

		let bytesPerPixel = framebuffer.sourceProperties.bytesPerPixel

		let numberOfSubRectangles = try await connection.readUInt32()
		var backgroundPixelValue = try await connection.read(length: bytesPerPixel)

		logger.logDebug("Received CoRRE Encoding number of sub rectangles: \(numberOfSubRectangles)")

		framebuffer.fill(region: rectangle.region,
						 withPixel: &backgroundPixelValue)

		for idx in 0..<numberOfSubRectangles {
			logger.logDebug("Receiving CoRRE Encoding Sub Rectangles \(idx + 1)/\(numberOfSubRectangles)")

			let subRectangle = try await SubRectangle.receive(bytesPerPixel: bytesPerPixel,
															  connection: connection)

			// rfbproto.rst, CoRRE Encoding (lines 3241-3274): RRE with each sub-rectangle's
			// position and size in a U8. Refused outside its rectangle for RRE's reasons; see
			// RREEncoding. The position used to be a UInt16 sum, which a rectangle within 255
			// pixels of 65535 overflowed.
			guard let subRegion = rectangle.subregion(x: Int(subRectangle.xPosition),
													  y: Int(subRectangle.yPosition),
													  width: Int(subRectangle.width),
													  height: Int(subRectangle.height)) else {
				throw VNCError.protocol(.subrectangleOutOfBounds(encodingType: encodingType,
																 subrectangle: .init(x: .init(subRectangle.xPosition),
																					 y: .init(subRectangle.yPosition),
																					 width: .init(subRectangle.width),
																					 height: .init(subRectangle.height)),
																 bounds: rectangle.region.size))
			}

			var foregroundPixelValue = subRectangle.pixelValue

			logger.logDebug("Received CoRRE Encoding Sub Rectangle \(idx + 1)/\(numberOfSubRectangles): \(subRectangle)")

			framebuffer.fill(region: subRegion,
							 withPixel: &foregroundPixelValue)
		}

		let region = rectangle.region

		framebuffer.didUpdate(region: region)
	}
}

private extension VNCProtocol.CoRREEncoding {
	struct SubRectangle {
		let pixelValue: Data

		let xPosition: UInt8
		let yPosition: UInt8

		let width: UInt8
		let height: UInt8
	}
}

private extension VNCProtocol.CoRREEncoding.SubRectangle {
	static func receive(bytesPerPixel: Int,
						connection: NetworkConnectionReading) async throws -> Self {
		let pixelValue = try await connection.read(length: bytesPerPixel)

		let xPosition = try await connection.readUInt8()
		let yPosition = try await connection.readUInt8()

		let width = try await connection.readUInt8()
		let height = try await connection.readUInt8()

		return .init(pixelValue: pixelValue,
					 xPosition: xPosition,
					 yPosition: yPosition,
					 width: width,
					 height: height)
	}
}
