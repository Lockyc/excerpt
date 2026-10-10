import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DecodedPNG {
    public let image: CGImage
    /// Pixels per point, from the PNG's DPI (72 DPI = 1×).
    public let scale: Double
}

public enum PNGCodec {
    /// A plain PNG whose DPI records the capture scale (144 DPI on Retina), so other apps show
    /// it at its on-screen size and excerpt can recover the scale from a flat file.
    public static func encode(_ image: CGImage, scale: Double) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { throw PNGError.encodeFailed }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PNGError.encodeFailed }
        return data as Data
    }

    /// Pixels per point from an image's DPI: 72 DPI is 1×, 144 is 2×. A DPI that rounds to a scale
    /// outside `EditDocument.scaleRange` (a 300 DPI scan, a damaged value) or no DPI at all reads
    /// as 1×, so the image is never shrunk past legibility or sized from garbage.
    public static func scale(dpi: Double?) -> Double {
        guard let dpi, dpi.isFinite else { return 1 }
        let scale = (dpi / 72).rounded()
        return EditDocument.scaleRange.contains(scale) ? scale : 1
    }

    public static func decode(_ data: Data) throws -> DecodedPNG {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PNGError.decodeFailed
        }
        // ImageIO sniffs content, so a JPEG renamed .png would otherwise open as a PNG.
        guard CGImageSourceGetType(source) as String? == UTType.png.identifier else {
            throw PNGError.notPNG
        }
        // ImageIO decodes a PNG cut short without complaint, filling the rest with grey: a file
        // still being copied or synced would open as grey rows and a save would keep them.
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            try PNGChunks.scan(data, keyword: PNGChunks.editsKeyword).isComplete,
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PNGError.decodeFailed }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return DecodedPNG(
            image: image, scale: scale(dpi: properties?[kCGImagePropertyDPIWidth] as? Double))
    }
}
