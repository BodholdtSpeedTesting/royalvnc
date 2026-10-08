#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct DesktopSizeEncoding: VNCReceivablePseudoEncoding {
		let encodingType = VNCPseudoEncodingType.desktopSize.rawValue
	}
}

extension VNCProtocol.DesktopSizeEncoding {
	func receive(_ rectangle: VNCProtocol.Rectangle,
				 framebuffer: VNCFramebuffer,
				 connection: NetworkConnectionReading,
				 logger: VNCLogger) async throws {
		// RFC 6143 7.8.2: "width and height indicate the new width and height of the
		// framebuffer". Refused above the ceiling before the framebuffer is replaced, which ends
		// the session: see VNCFramebuffer.maximumPixelCount.
		let newSize = rectangle.region.size

		try VNCFramebuffer.validateSize(newSize)

		framebuffer.resize(to: newSize)
	}
}
