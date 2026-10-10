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

    public static func decode(_ data: Data) throws -> DecodedPNG {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PNGError.decodeFailed }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return DecodedPNG(image: image, scale: max(1, (dpi / 72).rounded()))
    }
}
