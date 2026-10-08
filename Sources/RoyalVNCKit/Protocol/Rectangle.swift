#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct Rectangle {
		let xPosition: UInt16
		let yPosition: UInt16

		let width: UInt16
		let height: UInt16

		let encodingType: Int32
	}
}

extension VNCProtocol.Rectangle {
	static func receive(connection: NetworkConnectionReading) async throws -> Self {
		let xPosition = try await connection.readUInt16()
		let yPosition = try await connection.readUInt16()

		let width = try await connection.readUInt16()
		let height = try await connection.readUInt16()

		let encodingType = try await connection.readInt32()

		return .init(xPosition: xPosition,
					 yPosition: yPosition,
					 width: width,
					 height: height,
					 encodingType: encodingType)
	}

	var region: VNCRegion {
		return .init(location: .init(x: xPosition, y: yPosition),
					 size: .init(width: width, height: height))
	}

	/// The part of the framebuffer that an area given relative to this rectangle's top-left
	/// corner covers -- an RRE or CoRRE sub-rectangle, a Hextile tile -- or nil where the area
	/// does not lie inside this rectangle.
	///
	/// In `Int`, so that no sum of a rectangle's position and a position within it can overflow.
	/// Both are 16-bit numbers on the wire, and the decoders used to add them as `UInt16`: a
	/// sub-rectangle at x 0xFFFF in a rectangle at x 1 trapped.
	func subregion(x: Int,
				   y: Int,
				   width: Int,
				   height: Int) -> VNCRegion? {
		guard x >= 0,
			  y >= 0,
			  width >= 0,
			  height >= 0,
			  x + width <= Int(self.width),
			  y + height <= Int(self.height),
			  let regionX = UInt16(exactly: Int(xPosition) + x),
			  let regionY = UInt16(exactly: Int(yPosition) + y),
			  let regionWidth = UInt16(exactly: width),
			  let regionHeight = UInt16(exactly: height) else {
			return nil
		}

		return .init(x: regionX,
					 y: regionY,
					 width: regionWidth,
					 height: regionHeight)
	}
}
