import AVFoundation
import ExcerptCore
import Foundation
import ImageIO
import Testing

@testable import ExcerptRecording

@Suite struct ExporterTests {
    static func gif(_ url: URL) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    /// Each frame's delay in centiseconds, unclamped.
    static func delays(_ source: CGImageSource) throws -> [Int] {
        try (0..<CGImageSourceGetCount(source)).map { index in
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let seconds = try #require(
                (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime])
                    as? Double)
            return Int((seconds * 100).rounded())
        }
    }

    static func size(_ source: CGImageSource) throws -> CGSize {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    static func videoSize(_ url: URL) async throws -> CGSize {
        let track = try #require(
            try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try await track.load(.naturalSize)
    }

    static func moving(_ count: Int, width: Int = 120, height: Int = 80) -> [PixelBuffer] {
        (0..<count).map { SyntheticMaster.moving(width: width, height: height, phase: $0) }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func exportsAGifWithinBudget() async throws {
        let (master, paths) = try await SyntheticMaster.master(Self.moving(10))
        let edits = RecordingEdits.fresh(duration: master.duration, format: .gif)
        let result = try await RecordingExporter.export(master, edits: edits, to: paths)
        #expect(result.url == paths.primary(.gif))
        #expect(result.format == .gif)
        #expect(!result.fellBackToMP4)
        let attributes = try FileManager.default.attributesOfItem(atPath: result.url.path)
        #expect((attributes[.size] as? Int ?? .max) <= GIFEncoder.byteBudget)
        let source = try Self.gif(result.url)
        #expect(try Self.size(source) == CGSize(width: 60, height: 40))
        #expect(try Self.delays(source).reduce(0, +) == 100)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: paths.base.deletingLastPathComponent().path)
        #expect(Set(leftovers) == [paths.master.lastPathComponent, result.url.lastPathComponent])
    }

    @Test func fallsBackTo10fpsThenMP4() async throws {
        let (master, paths) = try await SyntheticMaster.master(Self.moving(30), fps: 30)
        let edits = RecordingEdits.fresh(duration: master.duration, format: .gif)
        let full = try await RecordingExporter.export(master, edits: edits, to: paths)
        let fullSource = try Self.gif(full.url)
        #expect(CGImageSourceGetCount(fullSource) == 15)
        let fullBytes = try Data(contentsOf: full.url).count

        // Every frame differs, so 10 fps is about two thirds the size of 15 fps; a budget between
        // the two stays clear of the decoder's small run-to-run variation in the frames.
        let slower = try await RecordingExporter.export(
            master, edits: edits, to: paths, byteBudget: fullBytes * 5 / 6)
        #expect(slower.format == .gif && !slower.fellBackToMP4)
        let slowerSource = try Self.gif(slower.url)
        #expect(CGImageSourceGetCount(slowerSource) == 10)
        #expect(try Self.delays(slowerSource) == Array(repeating: 10, count: 10))

        let video = try await RecordingExporter.export(
            master, edits: edits, to: paths, byteBudget: 100)
        #expect(video.url == paths.primary(.mp4))
        #expect(video.format == .mp4 && video.fellBackToMP4)
        #expect(Self.exists(video.url))
        #expect(!Self.exists(paths.primary(.gif)))
    }

    @Test func exportsOddSizedAreaAtBothScales() async throws {
        let (master, paths) = try await SyntheticMaster.master(
            Self.moving(3, width: 667, height: 402))
        #expect(master.pixelSize == CGSize(width: 666, height: 402))
        let gif = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .gif), to: paths)
        #expect(try Self.size(Self.gif(gif.url)) == CGSize(width: 333, height: 201))
        let mp4 = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .mp4), to: paths)
        #expect(try await Self.videoSize(mp4.url) == CGSize(width: 666, height: 402))
    }

    @Test func switchingFormatRemovesTheOtherPrimary() async throws {
        let (master, paths) = try await SyntheticMaster.master(Self.moving(5))
        _ = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .gif), to: paths)
        let mp4 = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .mp4), to: paths)
        #expect(!mp4.fellBackToMP4)
        #expect(Self.exists(paths.primary(.mp4)) && !Self.exists(paths.primary(.gif)))
        _ = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .gif), to: paths)
        #expect(Self.exists(paths.primary(.gif)) && !Self.exists(paths.primary(.mp4)))
    }

    @Test func trimmedFramesNeverReachThePrimary() async throws {
        let red = RGBA(r: 255, g: 0, b: 0, a: 255)
        let grey = RGBA(r: 128, g: 128, b: 128, a: 255)
        let frames = (0..<20).map {
            SyntheticMaster.solid($0 < 5 ? red : grey, width: 64, height: 48)
        }
        let (master, paths) = try await SyntheticMaster.master(frames)
        let edits = RecordingEdits(
            trim: 0.5...2, showsShortcuts: false, showsClicks: false, format: .gif)
        let source = try Self.gif(
            try await RecordingExporter.export(master, edits: edits, to: paths).url)
        #expect(try Self.delays(source).reduce(0, +) == 150)
        for index in 0..<CGImageSourceGetCount(source) {
            let frame = PixelBuffer(
                try #require(CGImageSourceCreateImageAtIndex(source, index, nil)))
            let reddish = (0..<frame.height).contains { y in
                (0..<frame.width).contains { x in
                    let pixel = frame[x: x, y: y]
                    return pixel.r > 180 && pixel.g < 100 && pixel.b < 100
                }
            }
            #expect(!reddish, "frame \(index) shows a trimmed frame")
        }
    }

    @Test func trimIsClampedToTheMaster() async throws {
        let (master, paths) = try await SyntheticMaster.master(Self.moving(10))
        let long = RecordingEdits(trim: 0...10, format: .gif)
        let source = try Self.gif(
            try await RecordingExporter.export(master, edits: long, to: paths).url)
        #expect(try Self.delays(source).reduce(0, +) == 100)
        let beyond = RecordingEdits(trim: 5...10, format: .gif)
        await #expect(throws: RecordingError.self) {
            try await RecordingExporter.export(master, edits: beyond, to: paths)
        }
    }
}
