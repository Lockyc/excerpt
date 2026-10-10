import CoreGraphics
import CoreText
import Foundation

/// The shapes annotations are drawn with, in original pixels: shared by the renderer, hit
/// testing and the hidden-annotation count, so all three agree on where an annotation is.
public enum AnnotationGeometry {
    public struct Arrow: Equatable, Sendable {
        /// Where the shaft stops: the middle of the head's base.
        public let shaftEnd: CGPoint
        /// The head triangle: tip, then the two base corners.
        public let head: [CGPoint]
    }

    /// The head is 3 stroke widths long and as wide, shortened to fit a short arrow.
    public static func arrow(tail: CGPoint, head: CGPoint, lineWidth: Double) -> Arrow {
        let dx = Double(head.x - tail.x)
        let dy = Double(head.y - tail.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return Arrow(shaftEnd: head, head: [head, head, head]) }
        let ux = dx / length
        let uy = dy / length
        let headLength = min(3 * lineWidth, length)
        let halfWidth = 1.5 * lineWidth * headLength / (3 * lineWidth)
        let base = CGPoint(x: Double(head.x) - ux * headLength, y: Double(head.y) - uy * headLength)
        return Arrow(
            shaftEnd: base,
            head: [
                head,
                CGPoint(x: Double(base.x) - uy * halfWidth, y: Double(base.y) + ux * halfWidth),
                CGPoint(x: Double(base.x) + uy * halfWidth, y: Double(base.y) - ux * halfWidth),
            ])
    }

    /// Stroke width in pixels.
    public static func lineWidth(_ annotation: Annotation, scale: Double) -> Double {
        annotation.width.points * scale
    }

    /// The original-pixel rect an annotation covers, stroke included.
    public static func bounds(of annotation: Annotation, scale: Double) -> CGRect {
        let w = lineWidth(annotation, scale: scale)
        switch annotation.shape {
        case .arrow(let tail, let head):
            let arrow = arrow(tail: tail, head: head, lineWidth: w)
            let points = [tail] + arrow.head
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(
                x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!,
                height: ys.max()! - ys.min()!
            )
            .insetBy(dx: -w / 2, dy: -w / 2)
        case .rectangle(let rect):
            return rect.standardized.insetBy(dx: -w / 2, dy: -w / 2)
        case .highlight(let rect), .blur(let rect):
            return rect.standardized
        case .text(let origin, let string):
            let size = TextLayout(
                string, pixelSize: annotation.width.textPoints * scale, color: .black
            ).size
            return CGRect(origin: origin, size: size)
        }
    }

    /// How many annotations lie wholly inside a removed band: the editor reports these
    /// ("1 annotation hidden by a cut").
    public static func hiddenCount(_ annotations: [Annotation], map: RenderMap, scale: Double)
        -> Int
    {
        annotations.filter { map.isHidden(bounds(of: $0, scale: scale)) }.count
    }
}

/// Text laid out one CoreText line per `\n`-separated line, in the emphasized system font.
public struct TextLayout {
    let lines: [CTLine]
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    let widths: [CGFloat]

    /// The one text font: annotation text is measured, drawn and typed in it. `pixelSize` is the
    /// text size in points times the capture scale (times the editor zoom when typing).
    public static func font(pixelSize: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, CGFloat(pixelSize), nil)!
    }

    init(_ string: String, pixelSize: Double, color: CGColor) {
        let font = Self.font(pixelSize: pixelSize)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        lines = string.components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        leading = CTFontGetLeading(font)
        widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
    }

    var lineHeight: CGFloat { ascent + descent + leading }

    var size: CGSize {
        CGSize(width: widths.max() ?? 0, height: lineHeight * CGFloat(lines.count))
    }
}
