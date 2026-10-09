#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Framebuffer Delegate
extension VNCConnection: VNCFramebufferDelegate {
	func framebuffer(_ framebuffer: VNCFramebuffer,
					 didUpdateRegion updatedRegion: VNCRegion) {
		notifyDelegateAboutFramebuffer(framebuffer,
									   updatedRegion: updatedRegion)
	}

	func framebuffer(_ framebuffer: VNCFramebuffer,
					 didUpdateDesktopName newDesktopName: String) {
		state.desktopName = newDesktopName
		desktopName = newDesktopName
	}

	func framebuffer(_ framebuffer: VNCFramebuffer,
					 didUpdateCursor cursor: VNCCursor) {
		notifyDelegateAboutUpdatedCursor(cursor)
	}

	func framebuffer(_ framebuffer: VNCFramebuffer,
					 sizeDidChange newSize: VNCSize,
					 screens newScreens: [VNCScreen]) {
		recreateFramebuffer(size: newSize,
							screens: newScreens,
							pixelFormat: framebuffer.sourcePixelFormat,
							colorMapFrom: framebuffer)
	}
}

extension VNCConnection {
	/// - Parameter previous: at a resize, the framebuffer the new one replaces, whose colour map
	///   it keeps. A resize leaves the pixel format as it was, and with it the colour map: only a
	///   SetPixelFormat empties that (rfbproto.rst, SetPixelFormat, lines 1684-1690), so the map
	///   is not carried where the client changes its pixel format (`updateColorDepth`).
	func recreateFramebuffer(size: VNCSize,
							 screens: [VNCScreen],
							 pixelFormat: VNCProtocol.PixelFormat,
							 colorMapFrom previous: VNCFramebuffer? = nil) {
		state.incrementalUpdatesEnabled = false

		let newFramebuffer: VNCFramebuffer

		do {
            newFramebuffer = try VNCFramebuffer(logger: logger,
                                                size: size,
                                                screens: screens,
                                                pixelFormat: pixelFormat,
                                                allocator: framebufferAllocator)
		} catch {
			handleBreakingError(error)

			return
		}

        self.framebuffer?.delegate = nil

		if let previous {
			newFramebuffer.inheritColorMap(from: previous)
		}

		newFramebuffer.delegate = self

		self.framebuffer = newFramebuffer

		notifyDelegateAboutFramebufferResize(newFramebuffer)
	}
}
