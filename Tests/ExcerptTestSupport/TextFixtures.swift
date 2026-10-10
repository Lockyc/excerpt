import CoreGraphics
import CoreText
import ExcerptCore
import Foundation

/// Real text, drawn with CoreText, for tests that run a real recogniser.
public enum TextFixtures {
    /// Black system-font lines on white, one every `lineHeight` points from the top, `scale`
    /// pixels per point. Line `i` is drawn with its baseline at `(i + 0.75) * lineHeight`.
    public static func page(
        _ lines: [String], width: Int, lineHeight: Int = 28, fontSize: Double = 15,
        scale: Double = 2
    ) -> CGImage {
        let pixelWidth = Int(Double(width) * scale)
        let pixelHeight = Int(Double(lines.count * lineHeight) * scale)
        let context = PixelBuffer.makeContext(width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let font = CTFontCreateUIFontForLanguage(.system, CGFloat(fontSize * scale), nil)!
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    gray: 0, alpha: 1),
            ]
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: line, attributes: attributes))
            let baseline = (Double(index) + 0.75) * Double(lineHeight) * scale
            context.textPosition = CGPoint(x: 12 * scale, y: Double(pixelHeight) - baseline)
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()!
    }
}
