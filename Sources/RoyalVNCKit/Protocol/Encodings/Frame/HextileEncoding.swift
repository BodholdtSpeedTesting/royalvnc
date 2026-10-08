#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct HextileEncoding: VNCFrameEncoding {
		let encodingType = VNCFrameEncodingType.hextile.rawValue

		static let tileSize: UInt16 = 16

		let rawEncoding: RawEncoding
	}
}

extension VNCProtocol.HextileEncoding {
	func decodeRectangle(_ rectangle: VNCProtocol.Rectangle,
						 framebuffer: VNCFramebuffer,
						 connection: NetworkConnectionReading,
						 logger: VNCLogger) async throws {
		logger.logDebug("Beginning to read Hextile Encoding")

		let bytesPerPixel = framebuffer.sourceProperties.bytesPerPixel

		// In Int: a tile's or a subrectangle's position added to the rectangle's in UInt16
		// overflowed, and trapped, within a tile of 65535 -- and a framebuffer that wide is one a
		// DesktopSize can set.
		let rectangleWidth = Int(rectangle.width)
		let rectangleHeight = Int(rectangle.height)

		let tileSize = Int(Self.tileSize)

		let xTileCount = (rectangleWidth + tileSize - 1) / tileSize
		let yTileCount = (rectangleHeight + tileSize - 1) / tileSize

		var lastBackgroundPixelData: Data?
		var lastForegroundPixelData: Data?

		for tileY in 0..<yTileCount {
			for tileX in 0..<xTileCount {
				// RFC 6143 7.7.4: 16x16 tiles, left to right and top to bottom, the last in a row
				// and the tiles of the last row "correspondingly smaller".
				let tileOffsetX = tileX * tileSize
				let tileOffsetY = tileY * tileSize

				guard let tileRegion = rectangle.subregion(x: tileOffsetX,
														   y: tileOffsetY,
														   width: min(tileSize, rectangleWidth - tileOffsetX),
														   height: min(tileSize, rectangleHeight - tileOffsetY)) else {
					// A tile lies inside its rectangle by construction; only a rectangle reaching
					// past 65535, which FramebufferUpdate.receive never lets through, can get here.
					// Refused rather than trapped all the same.
					throw VNCError.protocol(.invalidData)
				}

				let subencodingMask = try await connection.readUInt8()
				let subencoding = SubencodingMask(rawValue: subencodingMask)

				let isRaw = subencoding.contains(.raw)

				guard let rawEncodingType = rawEncoding.encodingType.int32Value else {
					fatalError("Failed to convert Raw Encoding type to Int32")
				}

				let tileRectangle = VNCProtocol.Rectangle(xPosition: tileRegion.x,
														  yPosition: tileRegion.y,
														  width: tileRegion.width,
														  height: tileRegion.height,
														  encodingType: rawEncodingType)

				if isRaw {
					try await rawEncoding.decodeRectangle(tileRectangle,
														  framebuffer: framebuffer,
														  connection: connection,
														  logger: logger)
				} else {
					let hasBackground = subencoding.contains(.backgroundSpecified)
					let hasForeground = subencoding.contains(.foregroundSpecified)
					let hasSubrects = subencoding.contains(.anySubrects)
					let subrectsColored = subencoding.contains(.subrectsColoured)

					let backgroundPixelData = hasBackground
						? try await connection.read(length: bytesPerPixel)
						: lastBackgroundPixelData

					let foregroundPixelData = hasForeground
						? try await connection.read(length: bytesPerPixel)
						: lastForegroundPixelData

					lastBackgroundPixelData = backgroundPixelData
					lastForegroundPixelData = foregroundPixelData

					if var backgroundPixelData = backgroundPixelData {
						framebuffer.fill(region: tileRectangle.region,
										 withPixel: &backgroundPixelData)
					}

					if hasSubrects {
						let subrectCount = try await connection.readUInt8()

						for _ in 0..<subrectCount {
							let subrectPixelData = subrectsColored
								? try await connection.read(length: bytesPerPixel)
								: foregroundPixelData

							let coords = try await connection.readUInt8()
							let dimensions = try await connection.readUInt8()

							let subrectX = Int(coords >> 4)
							let subrectY = Int(coords & 0x0f)

							let subrectWidth = Int(dimensions >> 4) + 1
							let subrectHeight = Int(dimensions & 0x0f) + 1

							// 7.7.4: the rectangle is "split up into 16x16 tiles, allowing the
							// dimensions of the subrectangles to be specified in 4 bits each" -- a
							// subrectangle is a part of its tile, at a position within it
							// (rfbproto.rst, Hextile Encoding, lines 3279-3288 and 3387-3392). One
							// reaching past its tile -- past 16, or past a narrower last tile -- is
							// refused, and the session ended, as an RRE sub-rectangle outside its
							// rectangle is and for the same reasons (RREEncoding).
							guard let subrectRegion = tileRectangle.subregion(x: subrectX,
																			  y: subrectY,
																			  width: subrectWidth,
																			  height: subrectHeight) else {
								throw VNCError.protocol(.subrectangleOutOfBounds(encodingType: encodingType,
																				 subrectangle: .init(x: .init(subrectX),
																									 y: .init(subrectY),
																									 width: .init(subrectWidth),
																									 height: .init(subrectHeight)),
																				 bounds: tileRegion.size))
							}

							if var subrectPixelData {
								framebuffer.fill(region: subrectRegion,
												 withPixel: &subrectPixelData)
							}
						}
					}
				}
			}
		}

		let region = rectangle.region

		framebuffer.didUpdate(region: region)
	}
}

private extension VNCProtocol.HextileEncoding {
	struct SubencodingMask: OptionSet {
		let rawValue: UInt8

		static let raw    				= SubencodingMask(rawValue: 1 << 0)
		static let backgroundSpecified  = SubencodingMask(rawValue: 1 << 1)
		static let foregroundSpecified  = SubencodingMask(rawValue: 1 << 2)
		static let anySubrects   		= SubencodingMask(rawValue: 1 << 3)
		static let subrectsColoured   	= SubencodingMask(rawValue: 1 << 4)
	}
}
