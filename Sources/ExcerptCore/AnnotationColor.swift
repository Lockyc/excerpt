import Foundation

/// An annotation's colour: one of the editor's palette or an exact colour sampled from the
/// capture. A palette colour encodes as its bare name, so a document using only the palette
/// keeps the shape an older build reads; a sampled colour encodes as its RGBA components.
public enum AnnotationColor: Codable, Equatable, Hashable, Sendable {
    case palette(Palette)
    case sampled(RGBA)

    /// What a new annotation gets.
    public static let initial = AnnotationColor.palette(.initial)

    public var rgba: RGBA {
        switch self {
        case .palette(let palette): palette.rgba
        case .sampled(let color): color
        }
    }

    /// The ink for text and numbers drawn on a fill of this colour: the palette's own choice,
    /// else black on a light sampled colour and white on a dark one.
    public var contrastingInk: RGBA {
        switch self {
        case .palette(let palette): palette.contrastingInk
        case .sampled(let color):
            Self.luminance(color) > 0.6
                ? RGBA(r: 0, g: 0, b: 0, a: 255) : RGBA(r: 255, g: 255, b: 255, a: 255)
        }
    }

    /// WCAG relative luminance of the sRGB components, 0 (black) to 1 (white).
    private static func luminance(_ color: RGBA) -> Double {
        func linear(_ byte: UInt8) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard let palette = Palette(rawValue: name) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath, debugDescription: "Unknown colour \(name)"))
            }
            self = .palette(palette)
        } else {
            self = .sampled(try RGBA(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .palette(let palette):
            var container = encoder.singleValueContainer()
            try container.encode(palette.rawValue)
        case .sampled(let color):
            try color.encode(to: encoder)
        }
    }
}
