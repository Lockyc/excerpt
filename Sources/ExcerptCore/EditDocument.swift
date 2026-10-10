import CoreGraphics
import Foundation

public enum EditDocumentError: Error, Equatable {
    /// Written by a newer excerpt; opening it here would silently drop what this build can't read.
    case unsupportedVersion(Int)
    /// A scale that is not a finite, positive pixels-per-point value would trap label formatting.
    case invalidScale(Double)
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
        let right = min(imageWidth, x + width)
        let bottom = min(imageHeight, y + height)
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

    public init(
        scale: Double, cuts: [Cut] = [], crop: PixelRect? = nil, annotations: [Annotation] = []
    ) {
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
    }

    /// Version 1 documents have no `crop` or `annotations` keys; they read as none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try container.decode(Double.self, forKey: .scale)
        cuts = try container.decode([Cut].self, forKey: .cuts)
        crop = try container.decodeIfPresent(PixelRect.self, forKey: .crop)
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }

    /// Always writes `currentVersion`: whatever was read is now in this build's shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(scale, forKey: .scale)
        try container.encode(cuts, forKey: .cuts)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encode(annotations, forKey: .annotations)
    }

    public var isEmpty: Bool { cuts.isEmpty && crop == nil && annotations.isEmpty }

    /// An id no annotation in this document has.
    public var nextAnnotationID: Int { (annotations.map(\.id).max() ?? 0) + 1 }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EditDocument {
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard (1...currentVersion).contains(version) else {
            throw EditDocumentError.unsupportedVersion(version)
        }
        let document = try JSONDecoder().decode(EditDocument.self, from: data)
        guard document.scale.isFinite, document.scale > 0 else {
            throw EditDocumentError.invalidScale(document.scale)
        }
        return document
    }
}
