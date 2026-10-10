import CoreGraphics
import CoreText
import Foundation

public enum SeamLabel {
    /// `⋯ 1,240 px hidden`: the removed length in points, as the user saw it on screen.
    public static func text(removedPixels: Int, scale: Double) -> String {
        let points = Int((Double(removedPixels) / scale).rounded())
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return "⋯ \(formatter.string(from: NSNumber(value: points))!) px hidden"
    }

    /// Draws the pill centred on `center` (top-left coordinates), turned 90° for vertical seams.
    static func draw(
        _ text: String, center: CGPoint, vertical: Bool, in context: CGContext, canvasHeight: Int,
        scale: Double
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
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let padX = CGFloat(7 * scale)
        let padY = CGFloat(2 * scale)
        let pill = CGSize(width: textWidth + 2 * padX, height: ascent + descent + 2 * padY)

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
        context.textPosition = CGPoint(x: -textWidth / 2, y: rect.minY + padY + descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
