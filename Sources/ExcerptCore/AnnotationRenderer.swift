import CoreGraphics
import CoreText

/// Draws annotations over a rendered base. The renderer uses it for export and the editor's
/// canvas uses it for every repaint, so both draw the same pixels.
public enum AnnotationRenderer {
    /// Highlights and filled paths multiply their colour at this opacity, so text under them stays dark.
    public static let highlightOpacity = 0.5
    /// A step's white ring, as a fraction of its diameter, so a step reads on dark content too.
    static let stepRing = 0.08

    /// Draws every annotation except blurs (the base stage applies those) onto `context`, a
    /// bottom-left-origin canvas `canvasHeight` rendered pixels tall, placed through `map`. An
    /// annotation the cuts hide (`AnnotationGeometry.isDrawn`) is skipped.
    public static func draw(
        _ annotations: [Annotation], map: RenderMap, scale: Double, in context: CGContext,
        canvasHeight: Int
    ) {
        let flip = CanvasFlip(height: canvasHeight)
        let numbers = AnnotationGeometry.stepNumbers(annotations)
        for annotation in annotations where !annotation.shape.isBlur {
            guard AnnotationGeometry.isDrawn(annotation, map: map, scale: scale) else { continue }
            let color = annotation.color.rgba.cgColor
            let w = CGFloat(AnnotationGeometry.lineWidth(annotation, scale: scale))
            context.saveGState()
            switch annotation.shape {
            case .arrow(let tail, let head):
                let from = map.point(tail)
                let to = map.point(head)
                let arrow = AnnotationGeometry.arrow(tail: from, head: to, lineWidth: Double(w))
                context.setStrokeColor(color)
                context.setFillColor(color)
                context.setLineWidth(w)
                context.setLineCap(.round)
                context.move(to: flip.point(from))
                context.addLine(to: flip.point(arrow.shaftEnd))
                context.strokePath()
                context.addLines(between: arrow.head.map(flip.point))
                context.closePath()
                context.fillPath()
            case .rectangle(let rect):
                if let placed = map.rect(rect.standardized) {
                    context.setStrokeColor(color)
                    context.setLineWidth(w)
                    context.setLineJoin(.round)
                    context.stroke(flip.rect(placed))
                }
            case .highlight(let rect):
                if let placed = map.rect(rect.standardized) {
                    context.setBlendMode(.multiply)
                    context.setFillColor(color.copy(alpha: CGFloat(highlightOpacity))!)
                    context.fill(flip.rect(placed))
                }
            case .text(let origin, let string, let background):
                let pixelSize = AnnotationGeometry.textPixelSize(annotation, scale: scale)
                let onPill = background == true
                let layout = TextLayout(
                    string, pixelSize: pixelSize,
                    color: onPill ? annotation.color.contrastingInk.cgColor : color)
                let topLeft = map.point(origin, bias: .after)
                if onPill {
                    let pill = AnnotationGeometry.pill(
                        around: CGRect(origin: topLeft, size: layout.size), pixelSize: pixelSize)
                    let radius = CGFloat(
                        AnnotationGeometry.pillRadius(
                            pixelSize: pixelSize, height: Double(pill.height)))
                    context.setFillColor(color)
                    context.addPath(
                        CGPath(
                            roundedRect: flip.rect(pill), cornerWidth: radius,
                            cornerHeight: radius, transform: nil))
                    context.fillPath()
                }
                context.textMatrix = .identity
                for (index, line) in layout.lines.enumerated() {
                    let baseline =
                        Double(topLeft.y) + Double(layout.ascent)
                        + Double(index) * Double(layout.lineHeight)
                    context.textPosition = flip.point(CGPoint(x: Double(topLeft.x), y: baseline))
                    CTLineDraw(line, context)
                }
            case .step(let center):
                drawStep(
                    numbers[annotation.id] ?? 0, at: flip.point(map.point(center)),
                    diameter: AnnotationGeometry.stepDiameter(annotation, scale: scale),
                    fill: color, ink: annotation.color.contrastingInk.cgColor, in: context)
            case .path(let points, let closed, let fill):
                let path = CGMutablePath()
                path.addLines(between: points.map { flip.point(map.point($0)) })
                if closed { path.closeSubpath() }
                if closed && fill {
                    context.saveGState()
                    context.setBlendMode(.multiply)
                    context.setFillColor(color.copy(alpha: CGFloat(highlightOpacity))!)
                    context.addPath(path)
                    context.fillPath()
                    context.restoreGState()
                }
                context.setStrokeColor(color)
                context.setLineWidth(w)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.addPath(path)
                context.strokePath()
            case .blur:
                break
            }
            context.restoreGState()
        }
    }

    /// A filled circle inside a white ring, its number centred in `ink`. `centre` is in the
    /// context's bottom-left-origin space. A number too wide for the circle shrinks to fit.
    private static func drawStep(
        _ number: Int, at centre: CGPoint, diameter: Double, fill: CGColor, ink: CGColor,
        in context: CGContext
    ) {
        let circle = CGRect(
            x: Double(centre.x) - diameter / 2, y: Double(centre.y) - diameter / 2,
            width: diameter, height: diameter)
        let ring = CGFloat(diameter * stepRing)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: circle)
        context.setFillColor(fill)
        context.fillEllipse(in: circle.insetBy(dx: ring, dy: ring))

        let digits = String(number)
        let room = (diameter - 2 * Double(ring)) * 0.75
        var layout = TextLayout(digits, pixelSize: diameter * 0.5, color: ink)
        if Double(layout.size.width) > room {
            layout = TextLayout(
                digits, pixelSize: diameter * 0.5 * room / Double(layout.size.width), color: ink)
        }
        let line = layout.lines[0]
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: Double(centre.x) - Double(glyphs.midX), y: Double(centre.y) - Double(glyphs.midY))
        CTLineDraw(line, context)
    }
}
