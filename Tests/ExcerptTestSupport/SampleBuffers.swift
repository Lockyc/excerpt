import CoreMedia
import CoreVideo
import ExcerptCore
import Foundation

/// A clock tests set by hand, standing in for the host clock a `MasterWriter` reads.
public final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = CMTime.zero

    public init() {}

    public func set(seconds: Double) {
        lock.withLock { time = CMTime(seconds: seconds, preferredTimescale: 600) }
    }
    public func now() -> CMTime { lock.withLock { time } }
}

public enum SampleBuffers {
    /// `frame` as an opaque BGRA sample stamped `seconds`, as a screen stream delivers it.
    public static func sample(_ frame: PixelBuffer, at seconds: Double) -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, frame.width, frame.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let buffer = pixels!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let source = (y * frame.width + x) * 4
                let target = base + y * rowBytes + x * 4
                target[0] = frame.bytes[source + 2]
                target[1] = frame.bytes[source + 1]
                target[2] = frame.bytes[source]
                target[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing,
            sampleBufferOut: &sample)
        return sample!
    }
}
