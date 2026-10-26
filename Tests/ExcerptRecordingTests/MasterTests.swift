import AVFoundation
import ExcerptCore
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

    @Test func pausedSamplesAreDroppedAndRetimed() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("paused.mov")
        let clock = TestClock()
        let writer = try MasterWriter(url: url, width: 64, height: 48, now: clock.now)
        let frame = SyntheticMaster.solid(Self.grey, width: 64, height: 48)
        let paused = SyntheticMaster.solid(Self.red, width: 64, height: 48)
        for index in 0..<10 {
            clock.set(seconds: Double(index) / 10)
            try await SyntheticMaster.append(frame, at: Double(index) / 10, to: writer)
        }
        clock.set(seconds: 1)
        writer.pause()
        for index in 20..<40 {
            clock.set(seconds: Double(index) / 10)
            writer.append(SyntheticMaster.sampleBuffer(paused, at: Double(index) / 10))
        }
        #expect(abs(writer.recordedTime - 1) < 0.001)
        clock.set(seconds: 5)
        writer.resume()
        for index in 50..<60 {
            clock.set(seconds: Double(index) / 10)
            try await SyntheticMaster.append(frame, at: Double(index) / 10, to: writer)
        }
        clock.set(seconds: 6)
        #expect(abs(writer.recordedTime - 2) < 0.001)
        #expect(writer.frameCount == 20)
        try await writer.finish(log: SyntheticMaster.log)

        let master = try await RecordingMaster.read(url)
        #expect(abs(master.duration - 2) < 0.05)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for seconds in [0.5, 1.05, 1.5] {
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
        let writer = try MasterWriter(url: url, width: 64, height: 48)
        await #expect(throws: RecordingError.empty) {
            try await writer.finish(log: SyntheticMaster.log)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelLeavesNoFile() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("cancelled.mov")
        let writer = try MasterWriter(url: url, width: 64, height: 48)
        try await SyntheticMaster.append(
            SyntheticMaster.solid(Self.grey, width: 64, height: 48), at: 0, to: writer)
        writer.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aMasterWithoutALogIsUnreadable() async throws {
        let url = try SyntheticMaster.folder().appendingPathComponent("plain.mov")
        try Data("not a movie".utf8).write(to: url)
        await #expect(throws: RecordingError.unreadableMaster(url)) {
            try await RecordingMaster.read(url)
        }
    }
}
