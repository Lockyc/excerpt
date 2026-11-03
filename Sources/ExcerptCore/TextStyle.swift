import CoreGraphics
import CoreText
import Foundation

/// The typeface family of annotation text.
public enum TextFont: String, Codable, CaseIterable, Sendable {
    case sans
    case mono
    case serif
}

/// Where a text annotation's `origin` sits on its lines. Not `TextAlignment`: that would clash
/// with SwiftUI's in the app.
public enum TextAlign: String, Codable, Sendable {
    /// `origin.x` is the left edge; lines align to it.
    case left
    /// `origin.x` is the horizontal centre; each line is centred on it.
    case centered
}

/// A text annotation's own typography, replacing the stroke-width size and the fixed bold sans.
/// Text without one (`Shape.text`'s `style` nil) is legacy: `StrokeWidth.textPoints`, bold,
/// sans, left.
public struct TextStyle: Codable, Equatable, Sendable {
    /// The sizes a text may have: what a decoded document is held to and what the editor offers.
    public static let pointsRange: ClosedRange<Double> = 4...200

    /// Text size in points.
    public var points: Double
    public var bold: Bool
    public var font: TextFont
    public var alignment: TextAlign

    public init(
        points: Double, bold: Bool = true, font: TextFont = .sans, alignment: TextAlign = .left
    ) {
        self.points = points
        self.bold = bold
        self.font = font
        self.alignment = alignment
    }
}

extension TextLayout {
    /// The CoreText font for `font` and `bold` at `pixelSize`. Sans bold is the emphasized
    /// system font legacy text has always used.
    static func makeFont(pixelSize: Double, font: TextFont, bold: Bool) -> CTFont {
        let size = CGFloat(pixelSize)
        func traited(_ base: CTFont) -> CTFont? {
            guard bold else { return base }
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait)
        }
        switch font {
        case .sans:
            let kind: CTFontUIFontType = bold ? .emphasizedSystem : .system
            return CTFontCreateUIFontForLanguage(kind, size, nil)
                ?? CTFontCreateWithName(".AppleSystemUIFont" as CFString, size, nil)
        case .mono:
            if let base = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil),
                let font = traited(base)
            {
                return font
            }
            return CTFontCreateWithName(
                (bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        case .serif:
            // New York, the system serif, has no name CoreText resolves (it substitutes
            // Helvetica or Times); only AppKit's font design reaches it, which Core avoids.
            let base = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil)
            return traited(base) ?? base
        }
    }
}
