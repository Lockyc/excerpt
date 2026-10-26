import AVFoundation
import CoreVideo
import ExcerptCore
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptRecording

/// A clock tests set by hand, standing in for the host clock a `MasterWriter` reads.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = CMTime.zero

    func set(seconds: Double) {
        lock.withLock { time = CMTime(seconds: seconds, preferredTimescale: 600) }
    }
    func now() -> CMTime { lock.withLock { time } }
}

enum SyntheticMaster {
    /// Writes `frames` as a master, one every `1 / fps` seconds from zero, with `log`.
    static func write(frames: [PixelBuffer], fps: Int, log: RecordingEventLog, to url: URL)
        async throws
    {
        let clock = TestClock()
        let writer = try MasterWriter(
            url: url, width: frames[0].width, height: frames[0].height, now: clock.now)
        for (index, frame) in frames.enumerated() {
            let time = Double(index) / Double(fps)
            clock.set(seconds: time)
            try await append(frame, at: time, to: writer)
        }
        clock.set(seconds: Double(frames.count) / Double(fps))
        try await writer.finish(log: log)
    }

    /// Appends `frame` stamped `seconds`, once the writer can take it: a real-time input drops
    /// what arrives while it is busy, and a fixture must not.
    static func append(_ frame: PixelBuffer, at seconds: Double, to writer: MasterWriter)
        async throws
    {
        while !writer.isReadyForMoreFrames { try await Task.sleep(for: .milliseconds(1)) }
        writer.append(sampleBuffer(frame, at: seconds))
    }

    static func sampleBuffer(_ frame: PixelBuffer, at seconds: Double) -> CMSampleBuffer {
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

    /// A solid frame.
    static func solid(_ color: RGBA, width: Int, height: Int) -> PixelBuffer {
        ScrollFixtures.paint(width: width, height: height) { _, _ in color }
    }

    /// Flat blocks shifted by `phase`, so every frame differs from the one before.
    static func moving(width: Int, height: Int, phase: Int) -> PixelBuffer {
        ScrollFixtures.paint(width: width, height: height) { x, y in
            let n = UInt8(((x + phase * 3) / 6 + y / 5 * 7) % 12)
            return RGBA(r: n &* 20, g: 255 &- n &* 13, b: (n % 3) &* 90, a: 255)
        }
    }

    static let log = RecordingEventLog(
        version: RecordingEventLog.version, scale: 2, shortcutsLogged: true,
        events: [
            .click(time: 0.2, x: 10, y: 12, button: .left),
            .shortcut(time: 0.4, label: "⌘K"),
        ])

    /// A fresh folder for one test's files.
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "excerpt-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A master of `frames` at `fps` in a fresh folder, and the paths its primaries go to.
    static func master(
        _ frames: [PixelBuffer], fps: Int = 10, log: RecordingEventLog = SyntheticMaster.log
    ) async throws -> (RecordingMaster, RecordingPaths) {
        let paths = try LibraryStore(folder: try folder()).reserveRecording(at: Date())
        try await write(frames: frames, fps: fps, log: log, to: paths.master)
        return (try await RecordingMaster.read(paths.master), paths)
    }
}
