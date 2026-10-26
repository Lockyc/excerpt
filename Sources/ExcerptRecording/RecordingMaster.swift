import AVFoundation
import ExcerptCore
import Foundation

public enum RecordingError: Error, Equatable, LocalizedError {
    /// Stopped before a single frame was recorded.
    case empty
    /// Not a movie, or a movie without a recording's event log.
    case unreadableMaster(URL)
    /// The master couldn't be written; the reason is the writer's.
    case recordingFailed(String)
    /// The master is saved and opens, but without its shortcuts and clicks.
    case eventsNotSaved(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Nothing was recorded."
        case .unreadableMaster(let url): "\(url.lastPathComponent) isn't a readable recording."
        case .recordingFailed(let reason): "The recording couldn't be saved: \(reason)"
        case .eventsNotSaved(let reason):
            "The recording was saved without its shortcuts and clicks: \(reason)"
        case .exportFailed(let reason): reason
        }
    }
}

/// A recording's master movie (`… original.mov`): its frames at full pixel resolution, and in
/// its metadata the event log and, once edited, the edit document.
public struct RecordingMaster: Sendable {
    public let url: URL
    public let pixelSize: CGSize
    /// Seconds.
    public let duration: Double
    public let log: RecordingEventLog
    public let edits: RecordingEdits?

    static let eventsKey = "com.lockyc.excerpt.events"
    static let editsKey = "com.lockyc.excerpt.edits"

    /// BT.709, tagged on every movie written so frames decode to the colours they were taken in.
    static let colorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Throws `unreadableMaster` for a file that isn't a movie or has no readable event log,
    /// and the edit document's own error for edits that are damaged or from a newer excerpt.
    public static func read(_ url: URL) async throws -> RecordingMaster {
        let asset = AVURLAsset(url: url)
        let size: CGSize
        let duration: CMTime
        let items: [AVMetadataItem]
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.unreadableMaster(url)
            }
            size = try await track.load(.naturalSize)
            duration = try await asset.load(.duration)
            items = try await asset.load(.metadata)
        } catch {
            throw RecordingError.unreadableMaster(url)
        }
        guard let logData = await value(eventsKey, in: items),
            let log = try? JSONDecoder().decode(RecordingEventLog.self, from: logData)
        else { throw RecordingError.unreadableMaster(url) }
        let edits = try await value(editsKey, in: items).map(RecordingEdits.decode)
        return RecordingMaster(
            url: url, pixelSize: size, duration: duration.seconds, log: log, edits: edits)
    }

    /// Replaces the master's edit document, keeping its frames and log.
    public static func writeEdits(_ edits: RecordingEdits, to url: URL) async throws {
        let master = try await read(url)
        try await writeMetadata(log: master.log, edits: edits, to: url)
    }

    /// Rewrites the master's metadata to hold `log` and `edits`: a passthrough export to a file
    /// beside it, which then replaces it, so the frames are copied, never re-encoded.
    static func writeMetadata(log: RecordingEventLog, edits: RecordingEdits?, to url: URL)
        async throws
    {
        let items = try metadata(log: log, edits: edits)
        guard
            let session = AVAssetExportSession(
                asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough)
        else { throw RecordingError.unreadableMaster(url) }
        session.metadata = items
        let temporary = temporaryURL(beside: url)
        do {
            try await session.export(to: temporary, as: .mov)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The movie metadata holding `log` and, when given, `edits`.
    static func metadata(log: RecordingEventLog, edits: RecordingEdits?) throws -> [AVMetadataItem]
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var items = [item(eventsKey, try encoder.encode(log))]
        if let edits { items.append(item(editsKey, try encoder.encode(edits))) }
        return items
    }

    private static func item(_ key: String, _ json: Data) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = String(decoding: json, as: UTF8.self) as NSString
        return item
    }

    private static func value(_ key: String, in items: [AVMetadataItem]) async -> Data? {
        let identifier = AVMetadataItem.identifier(forKey: key, keySpace: .quickTimeMetadata)
        guard let item = items.first(where: { $0.identifier == identifier }),
            let string = try? await item.load(.stringValue)
        else { return nil }
        return Data(string.utf8)
    }
}

/// A hidden, unique file in `url`'s folder with its extension, to write and then move into place.
func temporaryURL(beside url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(
        ".\(UUID().uuidString).\(url.pathExtension)")
}
