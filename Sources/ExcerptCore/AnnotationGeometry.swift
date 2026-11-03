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
        let halfWidth = headLength / 2
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

    /// The space around text on its background, as fractions of the text size: across, then
    /// down.
    static let pillPadding = (x: 0.35, y: 0.15)

    /// Text size in pixels; 0 for other kinds.
    public static func textPixelSize(_ annotation: Annotation, scale: Double) -> Double {
        (annotation.textStyle?.points ?? 0) * scale
    }

    /// A text annotation's lines laid out in `color` in its font; nil for other kinds.
    public static func textLayout(of annotation: Annotation, scale: Double, color: CGColor)
        -> TextLayout?
    {
        guard case .text(_, let string, _, _) = annotation.shape,
            let style = annotation.textStyle
        else { return nil }
        return TextLayout(
            string, pixelSize: style.points * scale, color: color, font: style.font,
            bold: style.bold)
    }

    /// Where a text annotation's lines sit, in original pixels, without its background; nil
    /// for other kinds. A centred text is centred on `origin.x`.
    public static func textRect(of annotation: Annotation, scale: Double) -> CGRect? {
        guard case .text(let origin, _, _, _) = annotation.shape,
            let layout = textLayout(of: annotation, scale: scale, color: .black)
        else { return nil }
        let size = layout.size
        let centred = annotation.textStyle?.alignment == .centered
        let left = Double(origin.x) - (centred ? Double(size.width) / 2 : 0)
        return CGRect(origin: CGPoint(x: left, y: Double(origin.y)), size: size)
    }

    /// The background pill around text occupying `text`.
    public static func pill(around text: CGRect, pixelSize: Double) -> CGRect {
        text.insetBy(dx: -pillPadding.x * pixelSize, dy: -pillPadding.y * pixelSize)
    }

    /// The pill's corner radius: 0.3 of the text size, or half the pill's height if that is less.
    static func pillRadius(pixelSize: Double, height: Double) -> Double {
        min(height / 2, 0.3 * pixelSize)
    }

    /// Step circle diameter in pixels.
    public static func stepDiameter(_ annotation: Annotation, scale: Double) -> Double {
        annotation.width.stepPoints * scale
    }

    /// Each step's number by id: `first` plus its rank among the steps in annotation order.
    public static func stepNumbers(_ annotations: [Annotation], first: Int = 1) -> [Int: Int] {
        var numbers: [Int: Int] = [:]
        for annotation in annotations where annotation.shape.isStep {
            numbers[annotation.id] = first + numbers.count
        }
        return numbers
    }

    public static func stepCount(_ annotations: [Annotation]) -> Int {
        annotations.lazy.filter(\.shape.isStep).count
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
        case .highlight(let rect), .blur(let rect), .patch(let rect, _):
            return rect.standardized
        case .text(_, _, let background, _):
            let text = textRect(of: annotation, scale: scale)!
            return background == true
                ? pill(around: text, pixelSize: textPixelSize(annotation, scale: scale)) : text
        case .step(let center):
            let r = stepDiameter(annotation, scale: scale) / 2
            return CGRect(
                x: Double(center.x) - r, y: Double(center.y) - r, width: 2 * r, height: 2 * r)
        case .path(let points, _, _):
            return extent(of: points).insetBy(dx: -w / 2, dy: -w / 2)
        }
    }

    /// The segments a path strokes: each vertex to the next, and the last back to the first
    /// when `closed` and there are three or more.
    public static func segments(_ points: [CGPoint], closed: Bool) -> [(CGPoint, CGPoint)] {
        var pairs = Array(zip(points, points.dropFirst()))
        if closed, points.count > 2 { pairs.append((points[points.count - 1], points[0])) }
        return pairs
    }

    /// The rect `points` span, unstroked; zero at the origin for none.
    public static func extent(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }
        return rect
    }

    /// Whether an annotation shows on the render: the one test the renderer and the hidden
    /// count share. It fails when the stroke-inflated bounds lie wholly inside a removed band, or
    /// when a rectangle or highlight collapses to nothing beside one (so a stroke whose raw rect
    /// is cut away never draws as a hairline on the seam).
    public static func isDrawn(_ annotation: Annotation, map: RenderMap, scale: Double) -> Bool {
        guard !map.isHidden(bounds(of: annotation, scale: scale)) else { return false }
        switch annotation.shape {
        case .rectangle(let rect), .highlight(let rect), .blur(let rect), .patch(let rect, _):
            return map.rect(rect.standardized) != nil
        case .arrow(let tail, let head):
            // Decided on the unstroked extent: a stroke poking past a band edge doesn't
            // rescue an arrow whose tail and head both lie inside the band.
            return !map.isHidden(
                CGRect(
                    x: min(tail.x, head.x), y: min(tail.y, head.y),
                    width: abs(head.x - tail.x), height: abs(head.y - tail.y)))
        case .path(let points, _, _):
            // Decided on the unstroked extent, as the arrow is.
            return !map.isHidden(extent(of: points))
        case .text, .step:
            return true
        }
    }

    /// How many annotations the render does not show: the editor reports these
    /// ("1 annotation hidden by a cut").
    public static func hiddenCount(_ annotations: [Annotation], map: RenderMap, scale: Double)
        -> Int
    {
        annotations.filter { !isDrawn($0, map: map, scale: scale) }.count
    }
}

/// Text laid out one CoreText line per `\n`-separated line, in the emphasized system font.
/// `@unchecked Sendable`: its CoreText lines are immutable once made.
public struct TextLayout: @unchecked Sendable {
    let lines: [CTLine]
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    let widths: [CGFloat]

    /// The one text font: annotation text is measured, drawn and typed in it. `pixelSize` is the
    /// text size in points times the capture scale (times the editor zoom when typing).
    /// Memoised by size in `TextCache`.
    public static func font(pixelSize: Double, font: TextFont = .sans, bold: Bool = true) -> CTFont
    {
        TextCache.shared.font(pixelSize: pixelSize, font: font, bold: bold) {
            makeFont(pixelSize: pixelSize, font: font, bold: bold)
        }
    }

    /// Memoised in `TextCache` by string, size, colour, font and weight: a repaint measures each
    /// text from its bounds, hit test, margin and hidden count as well as drawing it.
    init(
        _ string: String, pixelSize: Double, color: CGColor, font: TextFont = .sans,
        bold: Bool = true
    ) {
        self = TextCache.shared.layout(
            string, pixelSize: pixelSize, color: color, font: font, bold: bold
        ) {
            TextLayout(laying: string, pixelSize: pixelSize, color: color, font: font, bold: bold)
        }
    }

    private init(
        laying string: String, pixelSize: Double, color: CGColor, font textFont: TextFont,
        bold: Bool
    ) {
        let font = Self.font(pixelSize: pixelSize, font: textFont, bold: bold)
        lines = string.components(separatedBy: "\n").map { Self.line($0, font: font, color: color) }
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        leading = CTFontGetLeading(font)
        widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
    }

    /// One line of annotation text: the one place a string, font and colour become a `CTLine`,
    /// so what the renderer draws and what `TextMatcher` scores against are built alike.
    static func line(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes))
    }

    /// Draws `line` with its baseline's left end at `position`, in `context`'s own bottom-left
    /// coordinates: how every line of annotation text reaches the pixels.
    static func draw(_ line: CTLine, at position: CGPoint, in context: CGContext) {
        context.textMatrix = .identity
        context.textPosition = position
        CTLineDraw(line, context)
    }

    var lineHeight: CGFloat { ascent + descent + leading }

    var size: CGSize {
        CGSize(width: widths.max() ?? 0, height: lineHeight * CGFloat(lines.count))
    }
}

/// Fonts by size and text layouts by string, size and colour, shared by every thread that
/// renders. Each table holds at most `limit` entries and empties when full, so typing, which
/// lays out a new string per keystroke, can't grow it. `@unchecked Sendable`: `lock` guards both
/// tables, and what they hold is immutable.
final class TextCache: @unchecked Sendable {
    static let shared = TextCache()
    static let limit = 256

    private struct Key: Hashable {
        let string: String
        let pixelSize: Double
        let color: CGColor
        let font: TextFont
        let bold: Bool
    }

    private struct FontKey: Hashable {
        let pixelSize: Double
        let font: TextFont
        let bold: Bool
    }

    private let lock = NSLock()
    private var fonts: [FontKey: CTFont] = [:]
    private var layouts: [Key: TextLayout] = [:]

    /// The number of layouts held, for tests.
    var layoutCount: Int { lock.withLock { layouts.count } }

    func font(pixelSize: Double, font: TextFont, bold: Bool, make: () -> CTFont) -> CTFont {
        let key = FontKey(pixelSize: pixelSize, font: font, bold: bold)
        if let cached = lock.withLock({ fonts[key] }) { return cached }
        let made = make()
        lock.withLock {
            if fonts.count >= Self.limit { fonts.removeAll(keepingCapacity: true) }
            fonts[key] = made
        }
        return made
    }

    func layout(
        _ string: String, pixelSize: Double, color: CGColor, font: TextFont = .sans,
        bold: Bool = true, make: () -> TextLayout
    ) -> TextLayout {
        let key = Key(string: string, pixelSize: pixelSize, color: color, font: font, bold: bold)
        if let layout = lock.withLock({ layouts[key] }) { return layout }
        let layout = make()
        lock.withLock {
            if layouts.count >= Self.limit { layouts.removeAll(keepingCapacity: true) }
            layouts[key] = layout
        }
        return layout
    }
}
