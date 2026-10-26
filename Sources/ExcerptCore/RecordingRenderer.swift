import CoreGraphics
import CoreText
import Foundation

/// Turns a master frame into an output frame: blurs, then click rings, then the shortcut pill,
/// then the scale. The exporter and the recording editor's preview both draw through it.
public enum RecordingRenderer {
    /// `t` is seconds into the master. `outputScale` is output pixels per master pixel:
    /// `1 / log.scale` for a GIF, 1 for an MP4.
    public static func render(
        _ frame: CGImage, at t: Double, log: RecordingEventLog, edits: RecordingEdits,
        outputScale: Double
    ) -> CGImage {
        let blurred = BlurRenderer.apply(
            edits.blurRects(at: t), to: frame, scale: log.scale, salt: edits.blurSalt)
        let rings = edits.showsClicks ? ClickRings.rings(at: t, in: log.events) : []
        let pill =
            edits.showsShortcuts && log.shortcutsLogged
            ? ShortcutTimeline.pill(at: t, in: log.events) : nil
        let width = Int((Double(frame.width) * outputScale).rounded())
        let height = Int((Double(frame.height) * outputScale).rounded())
        let resized = width != frame.width || height != frame.height
        if rings.isEmpty && pill == nil && !resized { return blurred }

        let master = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let drawn: CGImage
        if rings.isEmpty && pill == nil {
            drawn = blurred
        } else {
            let context = PixelBuffer.makeContext(width: frame.width, height: frame.height)
            context.draw(blurred, in: master)
            let flip = CanvasFlip(height: frame.height)
            for ring in rings { drawRing(ring, scale: log.scale, flip: flip, in: context) }
            if let pill { drawPill(pill, scale: log.scale, in: context) }
            drawn = context.makeImage()!
        }
        guard resized else { return drawn }
        let context = PixelBuffer.makeContext(width: width, height: height)
        context.interpolationQuality = .high
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static let ringFrom = 10.0
    private static let ringTo = 22.0
    private static let ringStroke = 3.0
    private static let leftRing = CGColor(
        srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
    private static let rightRing = CGColor(
        srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)

    private static func drawRing(
        _ ring: (x: Double, y: Double, progress: Double, button: ClickButton), scale: Double,
        flip: CanvasFlip, in context: CGContext
    ) {
        let radius = (ringFrom + (ringTo - ringFrom) * ring.progress) * scale
        let centre = flip.point(CGPoint(x: ring.x, y: ring.y))
        let color = ring.button == .left ? leftRing : rightRing
        context.setStrokeColor(color.copy(alpha: CGFloat(1 - ring.progress))!)
        context.setLineWidth(CGFloat(ringStroke * scale))
        context.strokeEllipse(
            in: CGRect(
                x: Double(centre.x) - radius, y: Double(centre.y) - radius,
                width: radius * 2, height: radius * 2))
    }

    private static let pillTextSize = 15.0
    private static let pillRadius = 6.0
    private static let pillInsetX = 12.0
    private static let pillInsetY = 6.0
    private static let pillBottomMargin = 12.0

    private static func pillFont(pixelSize: Double) -> CTFont {
        let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: traits] as CFDictionary)
        let base = CTFontCreateUIFontForLanguage(.system, CGFloat(pixelSize), nil)!
        return CTFontCreateCopyWithAttributes(base, CGFloat(pixelSize), nil, descriptor)
    }

    private static func drawPill(
        _ pill: (label: String, count: Int), scale: Double, in context: CGContext
    ) {
        let text = pill.count > 1 ? "\(pill.label) ×\(pill.count)" : pill.label
        let font = pillFont(pixelSize: pillTextSize * scale)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ascent = CTFontGetAscent(font)
        let textHeight = ascent + CTFontGetDescent(font)
        let size = CGSize(
            width: textWidth + CGFloat(2 * pillInsetX * scale),
            height: textHeight + CGFloat(2 * pillInsetY * scale))
        // The context is bottom-left origin, so "above the bottom edge" is a plain y offset.
        let box = CGRect(
            x: (CGFloat(context.width) - size.width) / 2,
            y: CGFloat(pillBottomMargin * scale), width: size.width, height: size.height)
        let radius = CGFloat(pillRadius * scale)
        context.setFillColor(CGColor(gray: 0, alpha: 0.75))
        context.addPath(
            CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: box.minX + CGFloat(pillInsetX * scale),
            y: box.minY + CGFloat(pillInsetY * scale) + CTFontGetDescent(font))
        CTLineDraw(line, context)
    }
}
