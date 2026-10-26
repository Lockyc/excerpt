import CoreGraphics
import Foundation

/// What a recording is exported as.
public enum RecordingFormat: String, Codable, Sendable {
    case gif
    case mp4
}

/// A blur over a recording: a rectangle of master pixels, covering the whole clip or one span.
public struct RecordingBlur: Codable, Equatable, Sendable {
    public var rect: CGRect
    /// Seconds into the master the blur is on screen; nil covers the whole clip.
    public var span: ClosedRange<Double>?

    public init(rect: CGRect, span: ClosedRange<Double>? = nil) {
        self.rect = rect
        self.span = span
    }
}

/// Everything the user changed about a recording, stored with its master: the trim, blurs, which
/// overlays show, and the output format. Times are seconds into the master.
public struct RecordingEdits: Codable, Equatable, Sendable {
    public static let version = 1

    public var version: Int
    /// The part of the master that is kept.
    public var trim: ClosedRange<Double>
    public var blurs: [RecordingBlur]
    public var showsShortcuts: Bool
    public var showsClicks: Bool
    public var format: RecordingFormat
    /// Random per document and stored with it: seeds blur noise so it can't be recomputed from
    /// the blur rect alone.
    public var blurSalt: UInt64

    public init(
        trim: ClosedRange<Double>, blurs: [RecordingBlur] = [], showsShortcuts: Bool = true,
        showsClicks: Bool = true, format: RecordingFormat,
        blurSalt: UInt64 = .random(in: .min ... .max)
    ) {
        self.version = Self.version
        self.trim = trim
        self.blurs = blurs
        self.showsShortcuts = showsShortcuts
        self.showsClicks = showsClicks
        self.format = format
        self.blurSalt = blurSalt
    }

    /// A recording nothing has been changed on: the whole clip, both overlays on, a new salt.
    public static func fresh(duration: Double, format: RecordingFormat) -> RecordingEdits {
        RecordingEdits(trim: 0...duration, format: format)
    }

    /// The blur rectangles on screen `t` seconds into the master.
    public func blurRects(at t: Double) -> [CGRect] {
        blurs.compactMap { blur in
            guard let span = blur.span else { return blur.rect }
            return span.contains(t) ? blur.rect : nil
        }
    }

    /// Throws `invalidGeometry` unless the trim is finite and not empty, no more than
    /// `EditDocument.maximumAnnotations` blurs are held, and every blur rect and span is finite.
    func validate() throws {
        func finite(_ values: CGFloat...) -> Bool { values.allSatisfy(\.isFinite) }
        guard trim.lowerBound.isFinite, trim.upperBound.isFinite,
            trim.lowerBound < trim.upperBound,
            blurs.count <= EditDocument.maximumAnnotations,
            blurs.allSatisfy({ blur in
                finite(blur.rect.origin.x, blur.rect.origin.y, blur.rect.width, blur.rect.height)
                    && (blur.span.map { $0.lowerBound.isFinite && $0.upperBound.isFinite } ?? true)
            })
        else {
            throw EditDocumentError.invalidGeometry
        }
    }

    public static func decode(_ data: Data) throws -> RecordingEdits {
        struct Header: Decodable { let version: Int }
        let version: Int
        do {
            version = try JSONDecoder().decode(Header.self, from: data).version
        } catch { throw EditDocumentError.damaged }
        guard version == Self.version else { throw EditDocumentError.unsupportedVersion(version) }
        let edits: RecordingEdits
        do {
            edits = try JSONDecoder().decode(RecordingEdits.self, from: data)
        } catch { throw EditDocumentError.damaged }
        try edits.validate()
        return edits
    }
}
