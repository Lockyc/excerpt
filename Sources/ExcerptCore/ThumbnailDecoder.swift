import CoreGraphics
import Foundation
import ImageIO

/// Decodes the part of an image a small preview shows, at the size it shows, so a preview holds
/// and briefly costs about its own pixels whatever the size of the image behind it.
public enum ThumbnailDecoder {
    /// The image's pixel size from its header, without decoding it; nil when it isn't an image
    /// ImageIO reads.
    public static func pixelSize(of data: Data) -> CGSize? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(pixelSize)
    }

    /// The image's top `rows`, about `width` pixels wide and never wider than the image, decoded
    /// now rather than when first drawn. A PNG is read through a header claiming only `rows`
    /// (`PNGChunks.header`), so a stitched page's top costs the top's pixels to decode: ImageIO
    /// decodes a full-height thumbnail before any crop, and a crop (`cropping(to:)`) keeps its
    /// whole parent alive. Any other image is decoded whole at `width` and its top rows copied
    /// into an image of their own. Nil when the data isn't an image ImageIO reads.
    public static func topRows(of data: Data, rows: Int, width: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let pixels = pixelSize(source), rows > 0, width > 0
        else { return nil }
        let rows = min(rows, Int(pixels.height))
        let shrink = min(1, CGFloat(width) / pixels.width)
        if let head = PNGChunks.header(of: data, rows: rows),
            let provider = spliced(head, onto: data),
            let top = CGImageSourceCreateWithDataProvider(provider, nil)
        {
            return thumbnail(top, longest: max(pixels.width, CGFloat(rows)) * shrink)
        }
        guard
            let whole = thumbnail(source, longest: max(pixels.width, pixels.height) * shrink)
        else { return nil }
        guard rows < Int(pixels.height) else { return whole }
        let kept = Int((CGFloat(whole.height) * CGFloat(rows) / pixels.height).rounded(.up))
        return copyTop(of: whole, rows: max(1, kept))
    }

    private static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func thumbnail(_ source: CGImageSource, longest: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longest.rounded(.up))),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image's top `rows` in a buffer of their own, so the rest can be freed.
    private static func copyTop(of image: CGImage, rows: Int) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: image.width, height: rows, bitsPerComponent: 8,
                bytesPerRow: 0, space: space.model == .rgb ? space : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(
            image,
            in: CGRect(x: 0, y: rows - image.height, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The bytes of `data` with `head` in place of its first `head.count`, served without
    /// copying `data`, which may be a mapped file far larger than the part decoded.
    private static func spliced(_ head: Data, onto data: Data) -> CGDataProvider? {
        let bytes = Unmanaged.passRetained(Spliced(head: head, body: data)).toOpaque()
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                Unmanaged<Spliced>.fromOpaque(info!).takeUnretainedValue()
                    .copy(into: buffer, from: Int(position), count: count)
            },
            releaseInfo: { info in Unmanaged<Spliced>.fromOpaque(info!).release() })
        return CGDataProvider(directInfo: bytes, size: off_t(data.count), callbacks: &callbacks)
    }

    private final class Spliced {
        let head: Data
        let body: Data

        init(head: Data, body: Data) {
            self.head = head
            self.body = body
        }

        func copy(into buffer: UnsafeMutableRawPointer, from position: Int, count: Int) -> Int {
            let end = min(position + count, body.count)
            guard position < end else { return 0 }
            var at = position
            while at < end {
                let (source, upTo) = at < head.count ? (head, head.count) : (body, end)
                let length = min(upTo, end) - at
                source.withUnsafeBytes { bytes in
                    buffer.advanced(by: at - position).copyMemory(
                        from: bytes.baseAddress!.advanced(by: at), byteCount: length)
                }
                at += length
            }
            return end - position
        }
    }
}
