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

    @Test func anMP4FitsH264sLargestFrame() {
        func macroblocks(_ frame: (width: Int, height: Int, outputScale: Double)) -> Int {
            ((frame.width + 15) / 16) * ((frame.height + 15) / 16)
        }
        let limit = RecordingExporter.h264MaximumMacroblocks
        let fourK = RecordingExporter.mp4Frame(for: CGSize(width: 3840, height: 2160))
        #expect(fourK == (3840, 2160, 1))
        let odd = RecordingExporter.mp4Frame(for: CGSize(width: 667, height: 403))
        #expect(odd == (666, 402, 1))
        let fiveK = RecordingExporter.mp4Frame(for: CGSize(width: 5120, height: 2880))
        #expect(fiveK.width == 4096 && fiveK.height == 2304)
        #expect(fiveK.outputScale == 0.8)

        for size in [
            CGSize(width: 6016, height: 3384), CGSize(width: 5120, height: 2880),
            CGSize(width: 8001, height: 1501), CGSize(width: 2000, height: 5000),
        ] {
            let frame = RecordingExporter.mp4Frame(for: size)
            #expect(macroblocks(frame) <= limit, "\(size)")
            #expect(macroblocks(frame) > limit * 99 / 100, "\(size) scaled further than needed")
            #expect(frame.width % 2 == 0 && frame.height % 2 == 0)
            let aspect = Double(frame.width) / Double(frame.height)
            #expect(abs(aspect / (size.width / size.height) - 1) < 0.005, "\(size)")
            // The renderer's frame at this scale covers the video.
            #expect(Int((size.width * frame.outputScale).rounded()) >= frame.width)
            #expect(Int((size.height * frame.outputScale).rounded()) >= frame.height)
        }
    }

    /// With nothing logged the master is never rewritten, so it stays as the writer left it, in
    /// fragments.
    @Test func aMasterWithNoEventsExports() async throws {
        let quiet = RecordingEventLog(
            version: RecordingEventLog.version, scale: 2, shortcutsLogged: false, events: [])
        let (master, paths) = try await SyntheticMaster.master(Self.moving(10), log: quiet)
        #expect(try await RecordingMaster.frameTimes(master.url).count == 10)
        let gif = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .gif), to: paths)
        #expect(try Self.delays(Self.gif(gif.url)).reduce(0, +) == 100)
    }

    @Test func aFiveKRecordingExportsAnMP4() async throws {
        let (master, paths) = try await SyntheticMaster.master(
            Self.moving(2, width: 5120, height: 2880))
        let mp4 = try await RecordingExporter.export(
            master, edits: .fresh(duration: master.duration, format: .mp4), to: paths)
        #expect(try await Self.videoSize(mp4.url) == CGSize(width: 4096, height: 2304))
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

    @Test func theFrameAtATimeIsTheLastStampedByThenWithinTheTolerance() {
        let tolerance = RecordingExporter.frameTolerance
        let stamps = [0.2, 0.4, 0.4, 1.0]
        #expect(RecordingExporter.frameIndex(at: 0.5, in: []) == nil)
        #expect(RecordingExporter.frameIndex(at: 0, in: stamps) == 0)
        #expect(RecordingExporter.frameIndex(at: 0.3, in: stamps) == 0)
        #expect(RecordingExporter.frameIndex(at: 0.4 - tolerance / 2, in: stamps) == 2)
        #expect(RecordingExporter.frameIndex(at: 0.4 - tolerance * 2, in: stamps) == 0)
        #expect(RecordingExporter.frameIndex(at: 5, in: stamps) == 3)
    }

    /// The reader the export draws from shows the frame `frameIndex` names, every sample.
    @Test func theReaderShowsTheFrameFrameIndexPicks() async throws {
        let frames = (0..<10).map {
            SyntheticMaster.solid(
                RGBA(r: UInt8($0 * 25), g: 0, b: 0, a: 255), width: 32, height: 32)
        }
        let (master, _) = try await SyntheticMaster.master(frames)
        let stamps = try await RecordingMaster.frameTimes(master.url)
        let reader = try await FrameReader(master, range: 0...master.duration)
        defer { reader.cancel() }
        for sample in RecordingExporter.samples(over: 0...master.duration, fps: 30) {
            let k = try #require(RecordingExporter.frameIndex(at: sample.time, in: stamps))
            let red = Int(PixelBuffer(try reader.frame(at: sample.time))[x: 16, y: 16].r)
            #expect(abs(red - k * 25) <= 6, "\(sample.time) s")
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
