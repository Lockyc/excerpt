import CoreGraphics
import CoreText
import Foundation

public enum SeamLabel {
    /// `⋯ 1,240 px hidden`: the removed length in points, as the user saw it on screen.
    public static func text(removedPixels: Int, scale: Double) -> String {
        "⋯ \(LengthText.points(removedPixels, scale: scale)) hidden"
    }

    static func attributedLine(_ text: String, scale: Double) -> (
        line: CTLine, ascent: CGFloat, descent: CGFloat, width: CGFloat
    ) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, CGFloat(10 * scale), nil)!
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return (line, ascent, descent, width)
    }

    /// The pill's size before any rotation: text plus padding.
    static func pillSize(text: String, scale: Double) -> CGSize {
        let m = attributedLine(text, scale: scale)
        return CGSize(
            width: m.width + 2 * CGFloat(7 * scale),
            height: m.ascent + m.descent + 2 * CGFloat(2 * scale))
    }

    /// The centre along a seam for a pill `length` long: `desired` moved the least needed to
    /// keep the pill, with `margin` spare, inside `segment` when it fits there, else inside `0..<canvas`.
    static func clampedCentre(
        desired: Double, length: Double, segment: Range<Double>, canvas: Double, margin: Double
    ) -> Double {
        let room = length + 2 * margin
        let bounds = room <= segment.upperBound - segment.lowerBound ? segment : 0..<canvas
        let lo = bounds.lowerBound + room / 2
        let hi = bounds.upperBound - room / 2
        return lo <= hi ? min(max(desired, lo), hi) : canvas / 2
    }

    /// Draws the pill centred on `center` (top-left coordinates), turned 90° for vertical seams.
    static func draw(
        _ text: String, center: CGPoint, vertical: Bool, in context: CGContext, canvasHeight: Int,
        scale: Double
    ) {
        let m = attributedLine(text, scale: scale)
        let pill = pillSize(text: text, scale: scale)
        let padY = CGFloat(2 * scale)

        context.saveGState()
        let origin = CanvasFlip(height: canvasHeight).point(center)
        context.translateBy(x: origin.x, y: origin.y)
        if vertical { context.rotate(by: .pi / 2) }
        let rect = CGRect(
            x: -pill.width / 2, y: -pill.height / 2, width: pill.width, height: pill.height)
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
                transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.62))
        context.fillPath()
        context.textPosition = CGPoint(x: -m.width / 2, y: rect.minY + padY + m.descent)
        CTLineDraw(m.line, context)
        context.restoreGState()
    }
}
