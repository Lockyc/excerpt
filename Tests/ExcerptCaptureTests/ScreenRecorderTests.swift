import CoreMedia
import ExcerptCore
import ExcerptTestSupport
import Foundation
import ScreenCaptureKit
import Testing

@testable import ExcerptCapture
@testable import ExcerptRecording

/// Drives a recorder's writer with synthetic stream samples: no screen, no stream.
@MainActor @Suite struct ScreenRecorderTests {
    static let region = ScrollRegion(
        displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2,
        pixelRect: CGRect(x: 0, y: 0, width: 64, height: 48), primaryHeight: 600)
    static let frame = ScrollFixtures.paint(width: 64, height: 48) { x, _ in
        RGBA(r: UInt8(x * 3), g: 120, b: 60, a: 255)
    }
    static let log = RecordingEventLog(
        version: RecordingEventLog.version, scale: 2, shortcutsLogged: false,
        events: [.click(time: 0.1, x: 4, y: 4, button: .left)])

    /// A recorder whose writers run on `clock` and store events through `writeEvents`, and the
    /// writer it last made.
    @MainActor final class Harness {
        let clock = TestClock()
        var writer: MasterWriter?
        let master: URL
        lazy var recorder = ScreenRecorder { [unowned self] url, width, height, scale, logged in
            let writer = try MasterWriter(
                url: url, width: width, height: height, scale: scale, shortcutsLogged: logged,
                now: { [clock] in clock.now() }, writeEvents: writeEvents)
            self.writer = writer
            return writer
        }
        let writeEvents: @Sendable (RecordingEventLog, URL) async throws -> Void

        init(
            writeEvents: @escaping @Sendable (RecordingEventLog, URL) async throws -> Void = {
                try await RecordingMaster.writeMetadata(log: $0, edits: nil, to: $1)
            }
        ) throws {
            self.writeEvents = writeEvents
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "excerpt-recorder-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            master = folder.appendingPathComponent("master.mov")
        }

        @MainActor func begin() throws {
            try recorder.beginWriting(
                region: ScreenRecorderTests.region, master: master, shortcutsLogged: false)
        }

        /// Feeds a stream sample stamped `seconds`, once the encoder can take it.
        @MainActor func receive(at seconds: Double, status: SCFrameStatus = .complete)
            async throws
        {
            clock.set(seconds: seconds)
            while !(writer?.isReadyForMoreFrames ?? true) {
                try await Task.sleep(for: .milliseconds(1))
            }
            recorder.receive(
                ScreenRecorderTests.streamSample(
                    ScreenRecorderTests.frame, at: seconds, status: status))
        }
    }

    /// A sample carrying `status` the way an `SCStream` attaches it.
    static func streamSample(_ frame: PixelBuffer, at seconds: Double, status: SCFrameStatus)
        -> CMSampleBuffer
    {
        let sample = SampleBuffers.sample(frame, at: seconds)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)!
        let info = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        info[SCStreamFrameInfo.status.rawValue] = status.rawValue
        return sample
    }

    @Test func stopWithNoFramesLeavesNothing() async throws {
        let harness = try Harness()
        try harness.begin()
        // Idle and blank samples still carry an image; none of them is a new picture.
        try await harness.receive(at: 0, status: .idle)
        try await harness.receive(at: 0.1, status: .blank)
        harness.clock.set(seconds: 1)
        await #expect(throws: RecordingError.empty) {
            try await harness.recorder.stop(log: Self.log)
        }
        #expect(!FileManager.default.fileExists(atPath: harness.master.path))
    }

    @Test func limitFiresOnceAtMaximum() async throws {
        let harness = try Harness()
        var fired = 0
        harness.recorder.onLimit = { fired += 1 }
        try harness.begin()
        try await harness.receive(at: 0)
        // A still screen sends no samples: the limit is reached on the clock alone.
        harness.clock.set(seconds: ScreenRecorder.maximumDuration - 0.5)
        harness.recorder.checkLimit()
        #expect(fired == 0)
        harness.clock.set(seconds: ScreenRecorder.maximumDuration)
        harness.recorder.checkLimit()
        harness.clock.set(seconds: ScreenRecorder.maximumDuration + 1)
        harness.recorder.checkLimit()
        #expect(fired == 1)
        harness.clock.set(seconds: ScreenRecorder.maximumDuration)
        try await harness.recorder.stop(log: Self.log)
    }

    @Test func pauseKeepsRecordedTimeStill() async throws {
        let harness = try Harness()
        try harness.begin()
        try await harness.receive(at: 0)
        harness.clock.set(seconds: 2)
        harness.recorder.pause()
        harness.clock.set(seconds: 10)
        #expect(abs(harness.recorder.recordedTime - 2) < 0.001)
        harness.recorder.resume()
        harness.clock.set(seconds: 11)
        #expect(abs(harness.recorder.recordedTime - 3) < 0.001)
        try await harness.recorder.stop(log: Self.log)
    }

    @Test func failureFinishesWhatWasRecorded() async throws {
        let harness = try Harness()
        var failures: [Error] = []
        harness.recorder.onFailure = { failures.append($0) }
        try harness.begin()
        for index in 0..<10 { try await harness.receive(at: Double(index) / 10) }
        harness.recorder.streamFailed(ScrollCaptureError.streamStalled)
        harness.recorder.streamFailed(ScrollCaptureError.streamStalled)
        #expect(failures.count == 1)
        harness.clock.set(seconds: 1)
        try await harness.recorder.stop(log: Self.log)
        let master = try await RecordingMaster.read(harness.master)
        #expect(master.log == Self.log)
        #expect(abs(master.duration - 1) < 0.05)
    }

    @Test func discardLeavesNothing() async throws {
        let harness = try Harness()
        try harness.begin()
        try await harness.receive(at: 0)
        await harness.recorder.discard()
        #expect(!FileManager.default.fileExists(atPath: harness.master.path))
    }

    @Test func eventsThatFailToSaveKeepTheRecording() async throws {
        struct Unwritable: Error {}
        let harness = try Harness(writeEvents: { _, _ in throw Unwritable() })
        try harness.begin()
        try await harness.receive(at: 0)
        harness.clock.set(seconds: 0.5)
        await #expect {
            try await harness.recorder.stop(log: Self.log)
        } throws: { error in
            if case RecordingError.eventsNotSaved = error { return true }
            return false
        }
        #expect(try await RecordingMaster.read(harness.master).log.events.isEmpty)
    }
}
