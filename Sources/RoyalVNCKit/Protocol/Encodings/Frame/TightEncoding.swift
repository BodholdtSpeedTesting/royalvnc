#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

#if canImport(JPEG)
@_implementationOnly import JPEG
#endif

#if canImport(PNG)
@_implementationOnly import PNG
#endif

extension VNCProtocol {
	final class TightEncoding: VNCFrameEncoding {
#if canImport(CoreGraphics) && canImport(ImageIO)
        private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(.init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
        private static let directBitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
#endif
        
        let encodingType = VNCFrameEncodingType.tight.rawValue

        private var zStreams: [ZlibStream]
        
		init() {
			self.zStreams = [
				ZlibStream(),
				ZlibStream(),
				ZlibStream(),
				ZlibStream()
			]
		}

		static func supportsPixelFormat(_ pixelFormat: VNCProtocol.PixelFormat) -> Bool {
			pixelFormat.trueColor &&
			pixelFormat.bitsPerPixel == 32 &&
			pixelFormat.depth == 24 &&
			pixelFormat.redMax == 255 &&
			pixelFormat.greenMax == 255 &&
			pixelFormat.blueMax == 255
		}
	}
}

extension VNCProtocol.TightEncoding {
    func decodeRectangle(_ rectangle: VNCProtocol.Rectangle,
                         framebuffer: VNCFramebuffer,
                         connection: NetworkConnectionReading,
                         logger: VNCLogger) async throws {
//        logger.logDebug("Beginning to read Tight Encoding")
        
		let width = Int(rectangle.width)
		let height = Int(rectangle.height)

		guard width > 0,
			  height > 0 else {
			logger.logDebug("Nothing to Tight decode, skipping")
			return
		}

		let pixelFormat = framebuffer.sourcePixelFormat

		guard pixelFormat.trueColor else {
			throw VNCError.protocol(.notImplemented(feature: "Tight encoding for non-true-color pixel formats"))
		}

		let bytesPerPixel = framebuffer.sourceProperties.bytesPerPixel
		let tPixelSize = Self.tightPixelSize(pixelFormat: pixelFormat)
        
//        logger.logDebug("Reading Tight Encoding compression-control byte")
        
		let control = try await connection.readUInt8()

		resetZStreamsIfNeeded(control: control,
                              logger: logger)

		let subencoding = control & 0xF0
        
//        logger.logDebug("Read Tight Sub-Encoding: \(subencoding)")

		if subencoding == TightSubencoding.png.rawValue {
			throw VNCError.protocol(.notImplemented(feature: "Tight PNG subencoding"))
		}

		if (control & 0x80) != 0,
		   subencoding != TightSubencoding.fill.rawValue,
		   subencoding != TightSubencoding.jpeg.rawValue {
			throw VNCError.protocol(.notImplemented(feature: "Tight subencoding \(subencoding)"))
		}

		if subencoding == TightSubencoding.fill.rawValue {
//            logger.logDebug("Reading Tight Fill Sub-Encoding pixel data of size \(tPixelSize)")
            
			var pixelData = try await connection.read(length: tPixelSize)

			if tPixelSize != bytesPerPixel {
//                logger.logDebug("Converting Tight TPixel Data")
                
                pixelData = try Self.convertTPixelData(
                    pixelData,
                    pixelFormat: pixelFormat,
                    bytesPerPixel: bytesPerPixel,
                    tPixelSize: tPixelSize
                )
			}

			framebuffer.fill(region: rectangle.region,
							 withPixel: &pixelData)

			framebuffer.didUpdate(region: rectangle.region)
            
			return
		}

		if subencoding == TightSubencoding.jpeg.rawValue {
			guard Self.supportsPixelFormat(pixelFormat) else {
				throw VNCError.protocol(.notImplemented(feature: "Tight JPEG decoding for current pixel format"))
			}
            
//            logger.logDebug("Reading Tight JPEG Sub-Encoding length")

			let jpegLength = try await readCompactLength(connection: connection,
                                                         logger: logger)
            
//            logger.logDebug("Reading Tight JPEG Sub-Encoding data (JPEG Length: \(jpegLength))")
            
            let jpegData = try await readBuffered(connection: connection,
                                                  length: jpegLength,
                                                  logger: logger)
            
//            logger.logDebug("Decoding Tight JPEG Sub-Encoding image data")

            // A JPEG that cannot be read ends the session with the error, as compressed data that
            // cannot be inflated does: a server sending one breaks the protocol. Away from Apple's
            // platforms the decoder is swift-jpeg, whose own errors used to reach the embedder as
            // they were -- a LexingError, not a VNCError with something to show.
            var decoded: Data

            do {
                decoded = try Self.decodeImageData(
                    jpegData,
                    imageType: .jpeg,
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    bytesPerPixel: bytesPerPixel
                )
            } catch let error as VNCError {
                throw error
            } catch {
                throw VNCError.protocol(.frameDecode(encodingType: encodingType, underlyingError: error))
            }

            framebuffer.update(region: rectangle.region,
                               data: &decoded)

			framebuffer.didUpdate(region: rectangle.region)
            
			return
		}

		let streamID = Int((control >> 4) & 0x03)
		let explicitFilter = (control & 0x40) != 0
        
        let filterID: UInt8
        
        if explicitFilter {
//            logger.logDebug("Reading explicit Tight Filter ID")
            filterID = try await connection.readUInt8()
        } else {
            filterID = TightFilter.copy.rawValue
        }

		switch filterID {
			case TightFilter.copy.rawValue:
				let expectedSize = width * height * tPixelSize
            
//                logger.logDebug("Reading Tight Copy Data of size \(expectedSize)")
                
                var rawData = try await readTightData(
                    connection: connection,
                    expectedSize: expectedSize,
                    streamID: streamID,
                    control: control,
                    logger: logger
                )

				if tPixelSize != bytesPerPixel {
//                    logger.logDebug("Converting Tight TPixel Data of size \(tPixelSize)")
                    
                    rawData = try Self.convertTPixelData(
                        rawData,
                        pixelFormat: pixelFormat,
                        bytesPerPixel: bytesPerPixel,
                        tPixelSize: tPixelSize
                    )
				}

                framebuffer.update(region: rectangle.region,
                                   data: &rawData)

			case TightFilter.palette.rawValue:
//                logger.logDebug("Reading Tight Palette size")
            
				let paletteSize = Int(try await connection.readUInt8()) + 1
				let paletteBytes = paletteSize * tPixelSize
            
//                logger.logDebug("Reading Tight Raw Palette Data of size \(paletteBytes)")

				let rawPaletteData = try await connection.read(length: paletteBytes)
            
//                logger.logDebug("Converting Tight Palette Data")
                
                let paletteData = try Self.convertPaletteData(
                    rawPaletteData,
                    pixelFormat: pixelFormat,
                    bytesPerPixel: bytesPerPixel,
                    tPixelSize: tPixelSize
                )

				let indexDataSize: Int
                
				if paletteSize == 2 {
					let bytesPerRow = (width + 7) / 8
					indexDataSize = bytesPerRow * height
				} else {
					indexDataSize = width * height
				}
            
//                logger.logDebug("Reading Tight Palette Data")

                let indices = try await readTightData(
                    connection: connection,
                    expectedSize: indexDataSize,
                    streamID: streamID,
                    control: control,
                    logger: logger
                )
            
//                logger.logDebug("Expanding Tight Palette")

                var decoded = try Self.expandPalette(
                    indices: indices,
                    palette: paletteData,
                    paletteSize: paletteSize,
                    width: width,
                    height: height,
                    bytesPerPixel: bytesPerPixel
                )

                framebuffer.update(region: rectangle.region,
                                   data: &decoded)

			case TightFilter.gradient.rawValue:
				guard tPixelSize == 3 else {
					throw VNCError.protocol(.notImplemented(feature: "Tight Gradient Filter for current pixel format"))
				}
            
                let expectedSize = width * height * tPixelSize
            
//                logger.logDebug("Reading Tight Gradient data of size \(expectedSize)")
                
                let filteredData = try await readTightData(
                    connection: connection,
                    expectedSize: expectedSize,
                    streamID: streamID,
                    control: control,
                    logger: logger
                )
            
//                logger.logDebug("Decoding Tight Gradient data")

                var decoded = try Self.decodeGradient(
                    filteredData,
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    bytesPerPixel: bytesPerPixel
                )

                framebuffer.update(region: rectangle.region,
                                   data: &decoded)

			default:
				throw VNCError.protocol(.notImplemented(feature: "Tight Filter ID \(filterID)"))
		}

		framebuffer.didUpdate(region: rectangle.region)
	}
}

private extension VNCProtocol.TightEncoding {
    enum TightImageType {
        case jpeg
        case png
    }

	enum TightSubencoding: UInt8 {
		case fill = 0x80
		case jpeg = 0x90
		case png = 0xA0
	}

	enum TightFilter: UInt8 {
		case copy = 0
		case palette = 1
		case gradient = 2
	}

    func resetZStreamsIfNeeded(control: UInt8,
                               logger: VNCLogger) {
		for idx in 0..<4 {
			let mask = UInt8(1 << idx)
            
			if (control & mask) != 0 {
                logger.logDebug("Resetting Tight Encoding zStream at index \(idx)")
                
				do {
					try zStreams[idx].reset()
				} catch {
					zStreams[idx] = ZlibStream()
				}
			}
		}
	}

	func readCompactLength(connection: NetworkConnectionReading,
                           logger: VNCLogger) async throws -> Int {
		var length = 0
		var shift = 0

		for _ in 0..<3 {
//            logger.logDebug("Reading Tight Compact Length")
            
			let byte = try await connection.readUInt8()
			length |= Int(byte & 0x7F) << shift

			if (byte & 0x80) == 0 {
				return length
			}

			shift += 7
		}

		throw VNCError.protocol(.invalidData)
	}

	func readBuffered(connection: NetworkConnectionReading,
					  length: Int,
                      logger: VNCLogger) async throws -> Data {
		guard length > 0 else {
			return .init()
		}

		let chunkSize = 1024 * 16
        
//        logger.logDebug("Reading Tight Buffered Data (Length: \(length), Chunk Size: \(chunkSize))")
        
        let data = try await connection.readBuffered(
            length: length,
            minimumChunkSize: 1,
            maximumChunkSize: chunkSize
        )

		guard data.count == length else {
			throw VNCError.protocol(.invalidData)
		}

		return data
	}

    func readTightData(
        connection: NetworkConnectionReading,
        expectedSize: Int,
        streamID: Int,
        control: UInt8,
        logger: VNCLogger
    ) async throws -> Data {
		guard expectedSize > 0 else {
			return .init()
		}

		if expectedSize < 12 {
            let data = try await readBuffered(
                connection: connection,
                length: expectedSize,
                logger: logger
            )

			return data
		}

		let compressedLength = try await readCompactLength(connection: connection,
                                                           logger: logger)

		guard compressedLength > 0 else {
//			logger.logDebug("Tight: Compressed length is 0 (control=0x\(String(format: "%02X", control)), expectedSize=\(expectedSize))")
            
			throw VNCError.protocol(.invalidData)
		}

        let compressedData = try await readBuffered(
            connection: connection,
            length: compressedLength,
            logger: logger
        )

		do {
            return try zStreams[streamID].decompressedData(
                compressedData: compressedData,
                uncompressedSize: .init(expectedSize)
            )
		} catch {
			throw VNCError.protocol(.frameDecode(encodingType: encodingType, underlyingError: error))
		}
	}

	static func tightPixelSize(pixelFormat: VNCProtocol.PixelFormat) -> Int {
        if pixelFormat.trueColor,
           pixelFormat.bitsPerPixel == 32,
           pixelFormat.depth == 24,
           pixelFormat.redMax == 255,
           pixelFormat.greenMax == 255,
           pixelFormat.blueMax == 255 {
            return 3
        }

		return Int(pixelFormat.bitsPerPixel / 8)
	}

    static func convertPaletteData(
        _ paletteData: Data,
        pixelFormat: VNCProtocol.PixelFormat,
        bytesPerPixel: Int,
        tPixelSize: Int
    ) throws -> Data {
		guard tPixelSize != bytesPerPixel else {
			return paletteData
		}

        return try convertTPixelData(
            paletteData,
            pixelFormat: pixelFormat,
            bytesPerPixel: bytesPerPixel,
            tPixelSize: tPixelSize
        )
	}

    static func convertTPixelData(
        _ data: Data,
        pixelFormat: VNCProtocol.PixelFormat,
        bytesPerPixel: Int,
        tPixelSize: Int
    ) throws -> Data {
		guard tPixelSize == 3 else {
			throw VNCError.protocol(.notImplemented(feature: "Tight TPIXEL size \(tPixelSize) conversion"))
		}

		guard data.count % tPixelSize == 0 else {
			throw VNCError.protocol(.invalidData)
		}

		let pixelCount = data.count / tPixelSize
		let bitsPerPixel = Int(pixelFormat.bitsPerPixel)

		var converted = Data(count: pixelCount * bytesPerPixel)

		converted.withUnsafeMutableBytes { convertedPtr in
			var inputIndex = 0

			for pixelIndex in 0..<pixelCount {
				let red = data[inputIndex]
				let green = data[inputIndex + 1]
				let blue = data[inputIndex + 2]

                let pixelValue = packPixelValue(
                    red: red,
                    green: green,
                    blue: blue,
                    pixelFormat: pixelFormat
                )

				let offset = pixelIndex * bytesPerPixel

                storePixelValue(
                    pixelValue,
                    bitsPerPixel: bitsPerPixel,
                    targetPtr: convertedPtr.baseAddress,
                    offset: offset
                )

				inputIndex += tPixelSize
			}
		}

		return converted
	}

    static func expandPalette(
        indices: Data,
        palette: Data,
        paletteSize: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) throws -> Data {
		let pixelCount = width * height
		var output = Data(count: pixelCount * bytesPerPixel)
		var invalidIndex = false

		output.withUnsafeMutableBytes { outputPtr in
			guard let outputBase = outputPtr.baseAddress else {
				return
			}

			if paletteSize == 2 {
				let bytesPerRow = (width + 7) / 8

				for row in 0..<height {
					let rowStart = row * bytesPerRow

					for column in 0..<width {
						let byte = indices[rowStart + (column >> 3)]
						let bit = 7 - (column & 7)
						let paletteIndex = Int((byte >> bit) & 0x01)

						let sourceOffset = paletteIndex * bytesPerPixel
						let destinationOffset = (row * width + column) * bytesPerPixel

						let target = outputBase.advanced(by: destinationOffset)
                            .assumingMemoryBound(to: UInt8.self)
                        
                        palette.copyBytes(to: target,
                                          from: sourceOffset..<sourceOffset + bytesPerPixel)
					}
				}
			} else {
				for idx in 0..<pixelCount {
					let paletteIndex = Int(indices[idx])
                    
					guard paletteIndex < paletteSize else {
						invalidIndex = true
						return
					}
                    
					let sourceOffset = paletteIndex * bytesPerPixel
					let destinationOffset = idx * bytesPerPixel

					let target = outputBase.advanced(by: destinationOffset)
                        .assumingMemoryBound(to: UInt8.self)
                    
                    palette.copyBytes(to: target,
                                      from: sourceOffset..<sourceOffset + bytesPerPixel)
				}
			}
		}

		if invalidIndex {
			throw VNCError.protocol(.invalidData)
		}

		return output
	}

    static func decodeGradient(
        _ data: Data,
        width: Int,
        height: Int,
        pixelFormat: VNCProtocol.PixelFormat,
        bytesPerPixel: Int
    ) throws -> Data {
		guard data.count == width * height * 3 else {
			throw VNCError.protocol(.invalidData)
		}

		let pixelCount = width * height
		var output = Data(count: pixelCount * bytesPerPixel)

		var previousR = [Int](repeating: 0, count: width)
		var previousG = [Int](repeating: 0, count: width)
		var previousB = [Int](repeating: 0, count: width)

		var currentR = [Int](repeating: 0, count: width)
		var currentG = [Int](repeating: 0, count: width)
		var currentB = [Int](repeating: 0, count: width)

		let bitsPerPixel = Int(pixelFormat.bitsPerPixel)
		let maxValue = 255

		output.withUnsafeMutableBytes { outputPtr in
			guard let outputBase = outputPtr.baseAddress else {
				return
			}

			var dataIndex = 0

			for row in 0..<height {
				var leftR = 0
				var leftG = 0
				var leftB = 0

				for column in 0..<width {
					let diffR = Int(data[dataIndex])
					let diffG = Int(data[dataIndex + 1])
					let diffB = Int(data[dataIndex + 2])

					dataIndex += 3

					let upR = previousR[column]
					let upG = previousG[column]
					let upB = previousB[column]

					let upLeftR = column > 0 ? previousR[column - 1] : 0
					let upLeftG = column > 0 ? previousG[column - 1] : 0
					let upLeftB = column > 0 ? previousB[column - 1] : 0

					let predR = max(0, min(maxValue, leftR + upR - upLeftR))
					let predG = max(0, min(maxValue, leftG + upG - upLeftG))
					let predB = max(0, min(maxValue, leftB + upB - upLeftB))

					let valueR = (diffR + predR) & 0xFF
					let valueG = (diffG + predG) & 0xFF
					let valueB = (diffB + predB) & 0xFF

					currentR[column] = valueR
					currentG[column] = valueG
					currentB[column] = valueB

					leftR = valueR
					leftG = valueG
					leftB = valueB

					let offset = (row * width + column) * bytesPerPixel
                    
                    let pixelValue = packPixelValue(
                        red: UInt8(valueR),
                        green: UInt8(valueG),
                        blue: UInt8(valueB),
                        pixelFormat: pixelFormat
                    )

                    storePixelValue(
                        pixelValue,
                        bitsPerPixel: bitsPerPixel,
                        targetPtr: outputBase,
                        offset: offset
                    )
				}

				swap(&previousR, &currentR)
				swap(&previousG, &currentG)
				swap(&previousB, &currentB)

				for idx in 0..<width {
					currentR[idx] = 0
					currentG[idx] = 0
					currentB[idx] = 0
				}
			}
		}

		return output
	}

    static func packPixelValue(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        pixelFormat: VNCProtocol.PixelFormat
    ) -> Int {
		let redScaled = scaleComponent(red, maxValue: Int(pixelFormat.redMax))
		let greenScaled = scaleComponent(green, maxValue: Int(pixelFormat.greenMax))
		let blueScaled = scaleComponent(blue, maxValue: Int(pixelFormat.blueMax))

		let redShift = Int(pixelFormat.redShift)
		let greenShift = Int(pixelFormat.greenShift)
		let blueShift = Int(pixelFormat.blueShift)

		let pixelValue = (redScaled << redShift) |
                         (greenScaled << greenShift) |
                         (blueScaled << blueShift)

		return pixelValue
	}

	static func scaleComponent(_ value: UInt8,
							   maxValue: Int) -> Int {
		guard maxValue != 255 else {
			return Int(value)
		}

		return (Int(value) * maxValue + 127) / 255
	}

    static func storePixelValue(
        _ value: Int,
        bitsPerPixel: Int,
        targetPtr: UnsafeMutableRawPointer?,
        offset: Int
    ) {
		guard let targetPtr else {
			return
		}

		switch bitsPerPixel {
			case 32:
                targetPtr.storeBytes(of: UInt32(value),
                                     toByteOffset: offset,
                                     as: UInt32.self)
			case 16:
                targetPtr.storeBytes(of: UInt16(value),
                                     toByteOffset: offset,
                                     as: UInt16.self)
            case 8:
                targetPtr.storeBytes(of: UInt8(value),
                                     toByteOffset: offset,
                                     as: UInt8.self)
            default:
				break
		}
	}
}

private extension VNCProtocol.TightEncoding {
    static func decodeImageData(
        _ data: Data,
        imageType: TightImageType,
        width: Int,
        height: Int,
        pixelFormat: VNCProtocol.PixelFormat,
        bytesPerPixel: Int
    ) throws -> Data {
#if canImport(ImageIO) && canImport(CoreGraphics)
        let cfData = data as CFData

        guard let imageSource = CGImageSourceCreateWithData(cfData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw VNCError.protocol(.invalidData)
        }

        guard image.width == width,
              image.height == height else {
            throw VNCError.protocol(.invalidData)
        }

        let canUseDirectOutput = bytesPerPixel == 4 &&
            !pixelFormat.bigEndian &&
            pixelFormat.bitsPerPixel == 32 &&
            pixelFormat.depth == 24 &&
            pixelFormat.redMax == 255 &&
            pixelFormat.greenMax == 255 &&
            pixelFormat.blueMax == 255 &&
            pixelFormat.redShift == 16 &&
            pixelFormat.greenShift == 8 &&
            pixelFormat.blueShift == 0

        if canUseDirectOutput {
            let bytesPerRow = width * bytesPerPixel
            var output = Data(count: bytesPerRow * height)

            let drawResult = output.withUnsafeMutableBytes { ptr -> Bool in
                guard let baseAddress = ptr.baseAddress else {
                    return false
                }

                guard let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: Self.rgbColorSpace,
                    bitmapInfo: Self.directBitmapInfo.rawValue
                ) else {
                    return false
                }

                context.draw(image,
                             in: CGRect(x: 0, y: 0, width: width, height: height))

                return true
            }

            guard drawResult else {
                throw VNCError.protocol(.invalidData)
            }

            return output
        }

        let bytesPerRow = width * 4
        var rgbaData = Data(count: bytesPerRow * height)
        
        let drawResult = rgbaData.withUnsafeMutableBytes { ptr -> Bool in
            guard let baseAddress = ptr.baseAddress else {
                return false
            }

            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: Self.rgbColorSpace,
                bitmapInfo: Self.bitmapInfo.rawValue
            ) else {
                return false
            }

            context.draw(image,
                         in: CGRect(x: 0, y: 0, width: width, height: height))

            return true
        }

        guard drawResult else {
            throw VNCError.protocol(.invalidData)
        }

        let pixelCount = width * height
        let bitsPerPixel = Int(pixelFormat.bitsPerPixel)
        var output = Data(count: pixelCount * bytesPerPixel)

        output.withUnsafeMutableBytes { outputPtr in
            guard let outputBase = outputPtr.baseAddress else {
                return
            }

            var inputIndex = 0

            for idx in 0..<pixelCount {
                let red = rgbaData[inputIndex]
                let green = rgbaData[inputIndex + 1]
                let blue = rgbaData[inputIndex + 2]

                let pixelValue = packPixelValue(
                    red: red,
                    green: green,
                    blue: blue,
                    pixelFormat: pixelFormat
                )

                let offset = idx * bytesPerPixel

                storePixelValue(
                    pixelValue,
                    bitsPerPixel: bitsPerPixel,
                    targetPtr: outputBase,
                    offset: offset
                )

                inputIndex += 4
            }
        }

        return output
#else
        switch imageType {
        case .jpeg:
#if canImport(JPEG)
            let image = try decodeJPEG(data,
                                       width: width,
                                       height: height)

            guard image.size.x == width,
                  image.size.y == height else {
                throw VNCError.protocol(.invalidData)
            }

            let pixels = image.unpack(as: JPEG.RGB.self)
            let pixelCount = width * height

            guard pixels.count == pixelCount else {
                throw VNCError.protocol(.invalidData)
            }

            return packRGBData(
                pixels,
                bytesPerPixel: bytesPerPixel,
                pixelFormat: pixelFormat
            )
#else
            throw VNCError.protocol(.notImplemented(feature: "Tight JPEG decoding requires swift-jpeg on non-Apple platforms"))
#endif

        case .png:
#if canImport(PNG)
            var stream = TightImageDataStream(data)
            let image: PNG.Image = try .decompress(stream: &stream)

            guard image.size.x == width,
                  image.size.y == height else {
                throw VNCError.protocol(.invalidData)
            }

            let pixels = image.unpack(as: PNG.RGBA<UInt8>.self)
            let pixelCount = width * height

            guard pixels.count == pixelCount else {
                throw VNCError.protocol(.invalidData)
            }

            return packRGBAData(
                pixels,
                bytesPerPixel: bytesPerPixel,
                pixelFormat: pixelFormat
            )
#else
            throw VNCError.protocol(.notImplemented(feature: "Tight PNG decoding requires swift-png on non-Apple platforms"))
#endif
        }
#endif
    }
}

private extension VNCProtocol.TightEncoding {
    struct TightImageDataStream {
        private var bytes: [UInt8]
        private var index: Int = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        mutating func read(count: Int) -> [UInt8]? {
            guard count >= 0,
                  index + count <= bytes.count else {
                return nil
            }

            let slice = bytes[index..<index + count]
            index += count
            return Array(slice)
        }
    }
}

#if !(canImport(ImageIO) && canImport(CoreGraphics))
#if canImport(JPEG)
extension VNCProtocol.TightEncoding.TightImageDataStream: JPEG.Bytestream.Source {}

private extension VNCProtocol.TightEncoding {
    /// A Tight JPEG's image, decoded with swift-jpeg's staged interface so that nothing is made
    /// for it until its frame header has been checked against the rectangle.
    ///
    /// rfbproto.rst's JpegCompression (lines 3505-3533) is the rectangle's pixels as a JPEG, so
    /// the image is the rectangle's size. swift-jpeg's one-call decompress made the image the
    /// size its frame header declares -- up to 65535 x 65535 -- and the kit compared that with
    /// the rectangle only after decoding: a 175-byte update made a Linux viewer allocate
    /// gigabytes, and be killed. In ITU-T T.81's terms:
    /// - the frame header's number of lines (Y) and of samples per line (X) (B.2.2) must be the
    ///   rectangle's height and width before the image is made, and a JPEG with no frame header
    ///   before its first scan is refused -- as is a Y of zero, which leaves the height to a DNL:
    ///   decoded without one, swift-jpeg's inverse DCT traps on it;
    /// - a DNL segment (B.2.5), which defines or redefines Y after the first scan, is refused: Y
    ///   is the rectangle's height already, and a DNL would make the image taller again. It is
    ///   refused here before swift-jpeg parses it, because its DNL parser traps on a DNL of zero
    ///   lines (T.81 Table B.10 gives NL as 1 to 65,535); were this blanket refusal ever relaxed --
    ///   a DNL restating the height is legal -- NL's two bytes would have to be checked first;
    /// - more restart-delimited segments (B.2.4.4) than a scan's grid of data units holds is
    ///   refused before the scan is decoded: swift-jpeg's progressive AC and refining band decoders
    ///   clamp only the upper bound of a segment's row range, so a segment beginning at or past the
    ///   grid traps them (see the guard below);
    /// - every scan is decoded with `extend: false`, so that entropy-coded data holding more
    ///   lines than Y is not decoded as more of the image, as swift-jpeg's own decompress allows
    ///   for a first scan. Every one of the frame's lines is asked for, too: a scan whose data
    ///   ends before the frame's last block ends with swift-jpeg's truncatedEntropyCodedSegment,
    ///   where its own decompress stopped a first scan quietly at the end of a row of blocks and
    ///   drew the rows after it mid-grey. (ImageIO, on Apple's platforms, draws such a JPEG.)
    /// Otherwise the segments are taken in the order and the way swift-jpeg's own decompress takes
    /// them, but for application and comment segments, which are passed over unread wherever they
    /// are: swift-jpeg's decompress reads the first APP0 and the first APP1 among those directly
    /// after SOI as JFIF and EXIF and refuses a malformed one, where the kit, like ImageIO, draws
    /// such a JPEG. What is refused here is refused as invalidData; swift-jpeg's own errors are left
    /// to the caller, which ends the session with them as frameDecode.
    static func decodeJPEG(_ data: Data,
                           width: Int,
                           height: Int) throws -> JPEG.Data.Rectangular<JPEG.Common> {
        var stream = TightImageDataStream(data)
        var marker: (type: JPEG.Marker, data: [UInt8]) = try stream.segment()

        guard case .start = marker.type else {
            throw VNCError.protocol(.invalidData)
        }

        var dcTables = [JPEG.Table.HuffmanDC]()
        var acTables = [JPEG.Table.HuffmanAC]()
        var quantizationTables = [JPEG.Table.Quantization]()
        var restartInterval: JPEG.Header.RestartInterval?
        var frameHeader: JPEG.Header.Frame?

        // Up to the frame header: the tables and restart interval that may come before it.
        while frameHeader == nil {
            marker = try stream.segment()

            switch marker.type {
                case .frame(let process):
                    frameHeader = try .parse(marker.data, process: process)
                case .quantization:
                    quantizationTables += try JPEG.Table.parse(quantization: marker.data)
                case .huffman:
                    let tables = try JPEG.Table.parse(huffman: marker.data)

                    dcTables += tables.dc
                    acTables += tables.ac
                case .interval:
                    restartInterval = try .parse(marker.data)
                case .application, .comment, .arithmeticCodingCondition, .hierarchical, .expandReferenceComponents:
                    break
                default:
                    // Another start of image, an end, a scan, a DNL or a restart before any frame
                    // header.
                    throw VNCError.protocol(.invalidData)
            }
        }

        guard let frame = frameHeader,
              frame.size.x == width,
              frame.size.y == height else {
            throw VNCError.protocol(.invalidData)
        }

        // Only now is anything made at the frame's size: the rectangle's, which the update's own
        // check has kept inside the framebuffer.
        var context = try JPEG.Context<JPEG.Common>(frame: frame)

        dcTables.forEach { context.push(dc: $0) }
        acTables.forEach { context.push(ac: $0) }

        for table in quantizationTables {
            try context.push(quanta: table)
        }

        if let restartInterval {
            context.push(interval: restartInterval)
        }

        // The restart interval in force, in data units, as swift-jpeg's decoder reads it (nil when
        // none, or when a DRI of zero disables it). Tracked so that a scan's restart-delimited
        // segments can be bounded against the grid before they are decoded, below.
        var currentInterval = restartInterval?.interval

        marker = try stream.segment()

        while true {
            switch marker.type {
                case .scan:
                    let scan = try JPEG.Header.Scan.parse(marker.data, process: frame.process)
                    var segments = [[UInt8]]()

                    // The scan's entropy-coded data, one segment per restart interval, up to the
                    // first marker that is not a restart; the restarts' phases in order.
                    while true {
                        let segment: [UInt8]

                        (segment, marker) = try stream.segment(prefix: true)
                        segments.append(segment)

                        guard case .restart(let phase) = marker.type else {
                            break
                        }

                        guard phase == (segments.count - 1) % 8 else {
                            throw VNCError.protocol(.invalidData)
                        }
                    }

                    // More restart-delimited segments than the scan's grid of data units holds is
                    // refused before they are decoded. swift-jpeg decodes segment k over the data
                    // units [k * interval, (k + 1) * interval), and a progressive AC or refining
                    // scan turns that into the row range `blocks.lowerBound / units.x ..<
                    // min(blocks.upperBound / units.x, units.y)`, clamping only the upper bound; so
                    // a segment whose first unit is at or past the grid gives lowerBound > upperBound
                    // and traps (Range requires lowerBound <= upperBound). A conformant encoder
                    // never writes more segments than ceil(units / interval), so this refuses only a
                    // malformed stream. The grid is the single component's data units for a
                    // non-interleaved scan, the MCU grid for an interleaved one, matching which of
                    // swift-jpeg's decoders the scan reaches.
                    if segments.count > 1, let stride = currentInterval {
                        let unitCount: Int

                        if scan.components.count == 1,
                           let plane = context.spectral.index(forKey: scan.components[0].ci) {
                            let units = context.spectral[plane].units

                            unitCount = units.x * units.y
                        } else {
                            unitCount = context.spectral.blocks.x * context.spectral.blocks.y
                        }

                        guard (segments.count - 1) * stride < unitCount else {
                            throw VNCError.protocol(.invalidData)
                        }
                    }

                    try context.push(scan: scan,
                                     ecss: segments,
                                     extend: false)

                    // `marker` is the one after the scan already.
                    continue
                case .quantization:
                    for table in try JPEG.Table.parse(quantization: marker.data) {
                        try context.push(quanta: table)
                    }
                case .huffman:
                    let tables = try JPEG.Table.parse(huffman: marker.data)

                    tables.dc.forEach { context.push(dc: $0) }
                    tables.ac.forEach { context.push(ac: $0) }
                case .interval:
                    let parsedInterval = try JPEG.Header.RestartInterval.parse(marker.data)

                    context.push(interval: parsedInterval)
                    currentInterval = parsedInterval.interval
                case .end:
                    return context.spectral.idct().interleaved()
                case .application, .comment, .arithmeticCodingCondition, .hierarchical, .expandReferenceComponents:
                    break
                default:
                    // A DNL, a second frame header, another start of image, or a restart outside
                    // a scan.
                    throw VNCError.protocol(.invalidData)
            }

            marker = try stream.segment()
        }
    }
}
#endif

#if canImport(PNG)
extension VNCProtocol.TightEncoding.TightImageDataStream: PNG.BytestreamSource {}
#endif

private extension VNCProtocol.TightEncoding {
#if canImport(JPEG)
    static func packRGBData(
        _ pixels: [JPEG.RGB],
        bytesPerPixel: Int,
        pixelFormat: VNCProtocol.PixelFormat
    ) -> Data {
        let pixelCount = pixels.count
        let bitsPerPixel = Int(pixelFormat.bitsPerPixel)
        var output = Data(count: pixelCount * bytesPerPixel)

        output.withUnsafeMutableBytes { outputPtr in
            guard let outputBase = outputPtr.baseAddress else {
                return
            }

            for idx in 0..<pixelCount {
                let pixel = pixels[idx]

                let pixelValue = packPixelValue(
                    red: pixel.r,
                    green: pixel.g,
                    blue: pixel.b,
                    pixelFormat: pixelFormat
                )

                storePixelValue(
                    pixelValue,
                    bitsPerPixel: bitsPerPixel,
                    targetPtr: outputBase,
                    offset: idx * bytesPerPixel
                )
            }
        }

        return output
    }
#endif

#if canImport(PNG)
    static func packRGBAData(
        _ pixels: [PNG.RGBA<UInt8>],
        bytesPerPixel: Int,
        pixelFormat: VNCProtocol.PixelFormat
    ) -> Data {
        let pixelCount = pixels.count
        let bitsPerPixel = Int(pixelFormat.bitsPerPixel)
        var output = Data(count: pixelCount * bytesPerPixel)

        output.withUnsafeMutableBytes { outputPtr in
            guard let outputBase = outputPtr.baseAddress else {
                return
            }

            for idx in 0..<pixelCount {
                let pixel = pixels[idx]

                let pixelValue = packPixelValue(
                    red: pixel.r,
                    green: pixel.g,
                    blue: pixel.b,
                    pixelFormat: pixelFormat
                )

                storePixelValue(
                    pixelValue,
                    bitsPerPixel: bitsPerPixel,
                    targetPtr: outputBase,
                    offset: idx * bytesPerPixel
                )
            }
        }

        return output
    }
#endif
}
#endif
