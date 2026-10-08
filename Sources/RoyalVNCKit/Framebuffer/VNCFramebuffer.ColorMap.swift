#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCFramebuffer {
	/// The colour map of a session whose pixel format has one: where the true-colour flag is
	/// zero, pixel values "serve as indices into a color map" (RFC 6143 7.4), whose entries the
	/// server sets with SetColourMapEntries (7.6.2).
	///
	/// A message may set "only ... part of the color map" (7.6.2) -- "the server can set any of
	/// the entries in the colour map", and the map starts empty (rfbproto.rst, SetPixelFormat,
	/// lines 1684-1690) -- so an entry keeps its colour until a later message sets it again, and
	/// one no message has set has none.
	struct ColorMap {
		/// One entry per pixel value up to the highest set, nil where none has been set.
		private(set) var colors = [LocalPixel?]()

		var colorsCount: Int {
			colors.count
		}

		init() { }

		/// How many entries the colour map of a pixel format of `bitsPerPixel` bits has: one per
		/// pixel value those bits can hold -- 256 for the kit's 8-bit depth, the only one of its
		/// formats that uses a colour map -- and no more than one SetColourMapEntries can name,
		/// its first-colour and number-of-colours being U16s.
		static func capacity(bitsPerPixel: Int) -> Int {
			let nameable = Int(UInt16.max) + Int(UInt16.max)

			guard bitsPerPixel >= 0,
				  bitsPerPixel < 32 else {
				return nameable
			}

			return min(1 << bitsPerPixel, nameable)
		}

		/// Sets the entries `entries` names, `firstColour` onwards, one per colour sent. The
		/// caller has checked that they lie inside the map's capacity.
		mutating func set(_ entries: VNCProtocol.SetColourMapEntries) {
			let first = Int(entries.firstColour)
			let end = first + entries.colors.count

			if colors.count < end {
				colors.append(contentsOf: repeatElement(nil, count: end - colors.count))
			}

			for (offset, entry) in entries.colors.enumerated() {
				colors[first + offset] = LocalPixel(red: entry.redUInt8,
													green: entry.greenUInt8,
													blue: entry.blueUInt8)
			}
		}
	}
}

extension VNCFramebuffer.ColorMap {
	func colorAt(_ index: Int) -> VNCFramebuffer.LocalPixel? {
		guard index >= 0,
			  index < colorsCount else {
			return nil
		}

		return colors[index]
	}
}
