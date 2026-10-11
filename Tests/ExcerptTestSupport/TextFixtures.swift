import CoreGraphics
import CoreText
import ExcerptCore
import Foundation

/// Real text, drawn with CoreText, for tests that run a real recogniser.
public enum TextFixtures {
    /// A filled rectangle of system-font lines, in points: line `i` has its baseline at
    /// `(i + 0.75) * lineHeight` below the pane's top, 12pt in from its left.
    public struct Pane: Sendable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        public var background: Double
        public var ink: Double
        public var lineHeight: Int
        public var lines: [String]

        public init(
            x: Int, y: Int, width: Int, height: Int, background: Double = 1, ink: Double = 0,
            lineHeight: Int = 28, lines: [String]
        ) {
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
            (self.background, self.ink, self.lineHeight, self.lines) =
                (background, ink, lineHeight, lines)
        }
    }

    /// Black system-font lines on white, one every `lineHeight` points from the top, `scale`
    /// pixels per point. Line `i` is drawn with its baseline at `(i + 0.75) * lineHeight`.
    public static func page(
        _ lines: [String], width: Int, lineHeight: Int = 28, fontSize: Double = 15,
        scale: Double = 2
    ) -> CGImage {
        let height = lines.count * lineHeight
        return panes(
            [Pane(x: 0, y: 0, width: width, height: height, lineHeight: lineHeight, lines: lines)],
            width: width, height: height, fontSize: fontSize, scale: scale)
    }

    /// `panes` drawn in order on a white `width`×`height`-point image, `scale` pixels per point.
    public static func panes(
        _ panes: [Pane], width: Int, height: Int, fontSize: Double = 15, scale: Double = 2
    ) -> CGImage {
        let pixelWidth = Int(Double(width) * scale)
        let pixelHeight = Int(Double(height) * scale)
        let context = PixelBuffer.makeContext(width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let font = CTFontCreateUIFontForLanguage(.system, CGFloat(fontSize * scale), nil)!
        for pane in panes {
            context.setFillColor(CGColor(gray: pane.background, alpha: 1))
            context.fill(
                CGRect(
                    x: Double(pane.x) * scale,
                    y: Double(pixelHeight) - Double(pane.y + pane.height) * scale,
                    width: Double(pane.width) * scale, height: Double(pane.height) * scale))
            for (index, line) in pane.lines.enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                        gray: pane.ink, alpha: 1),
                ]
                let ctLine = CTLineCreateWithAttributedString(
                    NSAttributedString(string: line, attributes: attributes))
                let baseline =
                    (Double(pane.y) + (Double(index) + 0.75) * Double(pane.lineHeight)) * scale
                context.textPosition = CGPoint(
                    x: Double(pane.x + 12) * scale, y: Double(pixelHeight) - baseline)
                CTLineDraw(ctLine, context)
            }
        }
        return context.makeImage()!
    }
}
