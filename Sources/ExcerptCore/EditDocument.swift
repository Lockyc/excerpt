import CoreGraphics
import Foundation

public enum EditDocumentError: Error, Equatable, LocalizedError {
    /// Written by a newer excerpt; opening it here would silently drop what this build can't read.
    case unsupportedVersion(Int)
    /// A scale outside `EditDocument.scaleRange`: sizing labels, strokes and blur blocks from it
    /// would trap or exhaust memory.
    case invalidScale(Double)
    /// A cut bound, crop, annotation coordinate or annotation id outside
    /// `EditDocument.coordinateLimit` or `EditDocument.idLimit`, an id used twice, or more than
    /// `EditDocument.maximumCutsPerAxis` cuts on an axis.
    case invalidGeometry
    /// The edits JSON isn't a readable edit document at all.
    case damaged

    /// The one wording for why saved edits can't be used, shown by the app and `excerpt read`.
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "It was edited by a newer version of Excerpt."
        case .invalidScale, .invalidGeometry, .damaged: "Its saved edits are damaged."
        }
    }
}

/// A rectangle of whole original pixels, top-left origin.
public struct PixelRect: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// The part of this rect inside a `width`×`height` image; nil when none of it is.
    public func clamped(width imageWidth: Int, height imageHeight: Int) -> PixelRect? {
        let left = max(0, x)
        let top = max(0, y)
        let (farX, overflowX) = x.addingReportingOverflow(width)
        let (farY, overflowY) = y.addingReportingOverflow(height)
        guard !overflowX, !overflowY else { return nil }
        let right = min(imageWidth, farX)
        let bottom = min(imageHeight, farY)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Everything the user changed about a capture, stored in the master PNG: cuts, an optional
/// crop and the annotations, all in original pixels. `scale` is the capture's pixels-per-point,
/// which turns pixel lengths into the points shown on labels and sizes strokes and text.
public struct EditDocument: Codable, Equatable, Sendable {
    /// Version 2 carries `crop` and `annotations`; a version 1 build rejects it rather than open
    /// it without them, so its next save can't erase them.
    public static let currentVersion = 2

    public var scale: Double
    public var cuts: [Cut]
    public var crop: PixelRect?
    public var annotations: [Annotation]
    /// Random per document and stored with it: seeds blur noise so it can't be recomputed from
    /// the blur rect alone.
    public var salt: UInt64

    public init(
        scale: Double, cuts: [Cut] = [], crop: PixelRect? = nil, annotations: [Annotation] = [],
        salt: UInt64 = .random(in: .min ... .max)
    ) {
        self.salt = salt
        self.scale = scale
        self.cuts = cuts
        self.crop = crop
        self.annotations = annotations
    }

    enum CodingKeys: String, CodingKey {
        case version
        case scale
        case cuts
        case crop
        case annotations
        case salt
    }

    /// Version 1 documents have no `crop`, `annotations` or `salt` keys; the first two read as
    /// none and the salt is drawn at random.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try container.decode(Double.self, forKey: .scale)
        cuts = try container.decode([Cut].self, forKey: .cuts)
        crop = try container.decodeIfPresent(PixelRect.self, forKey: .crop)
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
        salt =
            try container.decodeIfPresent(UInt64.self, forKey: .salt) ?? .random(in: .min ... .max)
    }

    /// Always writes `currentVersion`: whatever was read is now in this build's shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(scale, forKey: .scale)
        try container.encode(cuts, forKey: .cuts)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encode(annotations, forKey: .annotations)
        try container.encode(salt, forKey: .salt)
    }

    public var isEmpty: Bool { cuts.isEmpty && crop == nil && annotations.isEmpty }

    /// An id no annotation in this document has.
    public var nextAnnotationID: Int {
        let highest = annotations.map(\.id).max() ?? 0
        return highest == Int.max ? highest : highest + 1
    }

    /// The pixels-per-point a document may have: the Retina scales and between. Labels, strokes
    /// and blur blocks are sized from it, so a damaged scale is refused rather than rendered.
    public static let scaleRange = 1.0...3.0

    /// The largest magnitude, in original pixels, any stored cut bound, coordinate or size may
    /// have.
    public static let coordinateLimit = 1_000_000.0
    /// The most cuts a document may make on either axis. Each one is a seam to draw and
    /// multiplies the regions read for text, so a crafted master's thousands are refused.
    public static let maximumCutsPerAxis = 1_000
    /// Annotation ids are in `0..<idLimit`, which keeps `nextAnnotationID` clear of overflow.
    public static let idLimit = Int.max / 2

    /// Throws `invalidGeometry` unless every stored coordinate, size and id is in range and
    /// neither axis has more than `maximumCutsPerAxis` cuts.
    private func validateGeometry() throws {
        for axis in [Axis.horizontal, .vertical]
        where cuts.lazy.filter({ $0.axis == axis }).count > Self.maximumCutsPerAxis {
            throw EditDocumentError.invalidGeometry
        }
        let limit = Self.coordinateLimit
        for cut in cuts where abs(Double(cut.lower)) > limit || abs(Double(cut.upper)) > limit {
            throw EditDocumentError.invalidGeometry
        }
        func inRange(_ values: CGFloat...) -> Bool {
            values.allSatisfy { $0.isFinite && abs(Double($0)) <= limit }
        }
        func rectOK(_ r: CGRect) -> Bool {
            inRange(r.origin.x, r.origin.y, r.size.width, r.size.height)
                && r.size.width >= 0 && r.size.height >= 0
        }
        if let crop {
            let ok = [crop.x, crop.y, crop.width, crop.height].allSatisfy {
                abs(Double($0)) <= limit
            }
            guard ok, crop.width > 0, crop.height > 0 else {
                throw EditDocumentError.invalidGeometry
            }
        }
        var seen = Set<Int>()
        for note in annotations {
            guard (0..<Self.idLimit).contains(note.id), seen.insert(note.id).inserted else {
                throw EditDocumentError.invalidGeometry
            }
            let ok: Bool
            switch note.shape {
            case .arrow(let tail, let head): ok = inRange(tail.x, tail.y, head.x, head.y)
            case .text(let origin, _): ok = inRange(origin.x, origin.y)
            case .rectangle(let r), .highlight(let r), .blur(let r): ok = rectOK(r)
            }
            guard ok else { throw EditDocumentError.invalidGeometry }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EditDocument {
        struct Header: Decodable { let version: Int }
        let version: Int
        do {
            version = try JSONDecoder().decode(Header.self, from: data).version
        } catch { throw EditDocumentError.damaged }
        guard (1...currentVersion).contains(version) else {
            throw EditDocumentError.unsupportedVersion(version)
        }
        let document: EditDocument
        do {
            document = try JSONDecoder().decode(EditDocument.self, from: data)
        } catch { throw EditDocumentError.damaged }
        guard scaleRange.contains(document.scale) else {
            throw EditDocumentError.invalidScale(document.scale)
        }
        try document.validateGeometry()
        return document
    }
}
