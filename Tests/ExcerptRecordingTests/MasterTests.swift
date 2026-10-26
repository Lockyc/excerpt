import AVFoundation
import ExcerptCore
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptRecording

@Suite struct MasterTests {
    static let grey = RGBA(r: 128, g: 128, b: 128, a: 255)
    static let red = RGBA(r: 255, g: 0, b: 0, a: 255)

    @Test func masterRoundTripsTheLogAndEdits() async throws {
        let frames = (0..<10).map { SyntheticMaster.moving(width: 64, height: 48, phase: $0) }
        let (master, _) = try await SyntheticMaster.master(frames)
        #expect(master.log == SyntheticMaster.log)
        #expect(master.edits == nil)
        #expect(master.pixelSize == CGSize(width: 64, height: 48))
        #expect(abs(master.duration - 1) < 0.05)

        let edits = RecordingEdits(
            trim: 0.2...0.8,
            blurs: [RecordingBlur(rect: CGRect(x: 4, y: 4, width: 20, height: 10))],
            showsClicks: false, format: .mp4, blurSalt: 42)
        try await RecordingMaster.writeEdits(edits, to: master.url)
        let reread = try await RecordingMaster.read(master.url)
        #expect(reread.edits == edits)
        #expect(reread.log == SyntheticMaster.log)
        #expect(abs(reread.duration - master.duration) < 0.001)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: master.url.deletingLastPathComponent().path)
        #expect(leftovers == [master.url.lastPathComponent])
    }

    @Test func frameTimesAreEveryFrameStampInOrder() async throws {
        let frames = (0..<6).map { SyntheticMaster.moving(width: 64, height: 48, phase: $0) }
        let (master, _) = try await SyntheticMaster.master(frames, fps: 5)
        let times = try await RecordingMaster.frameTimes(master.url)
        #expect(times.count == 6)
        for (i, time) in times.enumerated() { #expect(abs(time - Double(i) / 5) < 0.002) }
    }

    @Test func pausedSamplesAreDroppedAndRetimed() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("paused.mov")
        let clock = TestClock()
        let writer = try SyntheticMaster.writer(url: url, width: 64, height: 48, clock: clock)
        let frame = SyntheticMaster.solid(Self.grey, width: 64, height: 48)
        let paused = SyntheticMaster.solid(Self.red, width: 64, height: 48)
        // Frames to 0.4 s, then a still screen sending none until the pause at 1 s.
        for index in 0..<5 {
            clock.set(seconds: Double(index) / 10)
            try await SyntheticMaster.append(frame, at: Double(index) / 10, to: writer)
        }
        clock.set(seconds: 1)
        writer.pause()
        for index in 20..<40 {
            clock.set(seconds: Double(index) / 10)
            writer.append(SampleBuffers.sample(paused, at: Double(index) / 10))
        }
        #expect(abs(writer.recordedTime - 1) < 0.001)
        clock.set(seconds: 5)
        writer.resume()
        // Taken while paused, delivered after Resume: shifted, it would land after 0.4 s.
        try await SyntheticMaster.append(paused, at: 4.8, to: writer)
        for index in 50..<60 {
            clock.set(seconds: Double(index) / 10)
            try await SyntheticMaster.append(frame, at: Double(index) / 10, to: writer)
        }
        clock.set(seconds: 6)
        #expect(abs(writer.recordedTime - 2) < 0.001)
        #expect(writer.frameCount == 15)
        try await writer.finish(log: SyntheticMaster.log)

        let master = try await RecordingMaster.read(url)
        #expect(abs(master.duration - 2) < 0.05)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for seconds in [0.5, 0.85, 0.95, 1.05, 1.5] {
            let image = try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            )
            .image
            let pixel = PixelBuffer(image)[x: 32, y: 24]
            #expect(pixel.r < 160 && pixel.g > 100, "a paused frame at \(seconds) s")
        }
    }

    @Test func emptyMasterThrowsAndLeavesNoFile() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("empty.mov")
        let writer = try SyntheticMaster.writer(url: url, width: 64, height: 48)
        await #expect(throws: RecordingError.empty) {
            try await writer.finish(log: SyntheticMaster.log)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelLeavesNoFile() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("cancelled.mov")
        let writer = try SyntheticMaster.writer(url: url, width: 64, height: 48)
        try await SyntheticMaster.append(
            SyntheticMaster.solid(Self.grey, width: 64, height: 48), at: 0, to: writer)
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func finishingTwiceThrowsAndKeepsTheMaster() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("twice.mov")
        let writer = try SyntheticMaster.writer(url: url, width: 64, height: 48)
        try await SyntheticMaster.append(
            SyntheticMaster.solid(Self.grey, width: 64, height: 48), at: 0, to: writer)
        try await writer.finish(log: SyntheticMaster.log)
        await #expect(throws: RecordingError.self) {
            try await writer.finish(log: SyntheticMaster.log)
        }
        #expect(try await RecordingMaster.read(url).log == SyntheticMaster.log)
    }

    @Test func aWriterThatCannotStartReportsItsFailure() async throws {
        let folder = try SyntheticMaster.folder()
        let url = folder.appendingPathComponent("gone.mov")
        let writer = try SyntheticMaster.writer(url: url, width: 64, height: 48)
        try FileManager.default.removeItem(at: folder)
        let frame = SyntheticMaster.solid(Self.grey, width: 64, height: 48)
        writer.append(SampleBuffers.sample(frame, at: 0))
        writer.append(SampleBuffers.sample(frame, at: 0.1))
        #expect(writer.frameCount == 0)
        await #expect {
            try await writer.finish(log: SyntheticMaster.log)
        } throws: { error in
            guard case .recordingFailed = error as? RecordingError else { return false }
            return true
        }
    }

    @Test func aMasterWhoseEventsFailToSaveStillOpens() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("no events.mov")
        struct RewriteFailed: Error {}
        let writer = try SyntheticMaster.writer(
            url: url, width: 64, height: 48, writeEvents: { _, _ in throw RewriteFailed() })
        try await SyntheticMaster.append(
            SyntheticMaster.solid(Self.grey, width: 64, height: 48), at: 0, to: writer)
        await #expect {
            try await writer.finish(log: SyntheticMaster.log)
        } throws: { error in
            guard case .eventsNotSaved = error as? RecordingError else { return false }
            return true
        }
        let master = try await RecordingMaster.read(url)
        #expect(master.log.events.isEmpty)
        #expect(master.log.scale == SyntheticMaster.log.scale)
        #expect(master.log.shortcutsLogged == SyntheticMaster.log.shortcutsLogged)
    }

    @Test func aFileThatIsNotAMovieIsUnreadable() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("plain.mov")
        try Data("not a movie".utf8).write(to: url)
        await #expect(throws: RecordingError.unreadableMaster(url)) {
            try await RecordingMaster.read(url)
        }
    }
}
