import CoreGraphics
import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255)
    }
}

/// Premultiplied RGBA8 pixels in sRGB, row-major with the top row first: the one pixel layout
/// Core reads and writes, so drawing and inspection agree byte for byte.
public struct PixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height * 4)
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public init(_ image: CGImage) {
        let context = Self.makeContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = image.width * image.height * 4
        let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
        self.init(
            width: image.width, height: image.height,
            bytes: Array(UnsafeBufferPointer(start: pointer, count: count)))
    }

    public subscript(x x: Int, y y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
    }

    public func makeImage() -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Share of pixels where any channel differs by more than `tolerance`.
    public func fractionDiffering(from other: PixelBuffer, tolerance: UInt8) -> Double {
        precondition(width == other.width && height == other.height)
        var differing = 0
        for pixel in 0..<(width * height) {
            let i = pixel * 4
            for channel in 0..<4
            where abs(Int(bytes[i + channel]) - Int(other.bytes[i + channel])) > Int(tolerance) {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(width * height)
    }

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )

    /// A cleared bitmap context in the buffer layout. CoreGraphics' origin is bottom-left;
    /// callers convert from Core's top-left coordinates.
    public static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue)!
    }
}
