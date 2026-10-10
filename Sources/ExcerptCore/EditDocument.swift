import Foundation

public enum EditDocumentError: Error, Equatable {
    /// Written by a newer excerpt; opening it here would silently drop what this build can't read.
    case unsupportedVersion(Int)
    /// A scale that is not a finite, positive pixels-per-point value would trap label formatting.
    case invalidScale(Double)
}

/// Everything the user changed about a capture, stored in the master PNG. `scale` is the
/// capture's pixels-per-point, which turns pixel lengths into the points shown on labels.
public struct EditDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var scale: Double
    public var cuts: [Cut]

    public init(scale: Double, cuts: [Cut] = []) {
        self.version = Self.currentVersion
        self.scale = scale
        self.cuts = cuts
    }

    public var isEmpty: Bool { cuts.isEmpty }

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
