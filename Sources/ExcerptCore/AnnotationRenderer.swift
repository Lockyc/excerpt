import CoreGraphics
import CoreText

/// Draws annotations over a rendered base. The renderer uses it for export and the editor's
/// canvas uses it for every repaint, so both draw the same pixels.
public enum AnnotationRenderer {
    /// Highlights multiply their colour at this opacity, so text under them stays dark.
    public static let highlightOpacity = 0.5

    /// Draws every annotation except blurs (the base stage applies those) onto `context`, a
    /// bottom-left-origin canvas `canvasHeight` rendered pixels tall, placed through `map`. An
    /// annotation the cuts hide (`AnnotationGeometry.isDrawn`) is skipped.
    public static func draw(
        _ annotations: [Annotation], map: RenderMap, scale: Double, in context: CGContext,
        canvasHeight: Int
    ) {
        let flip = CanvasFlip(height: canvasHeight)
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
            case .text(let origin, let string):
                let layout = TextLayout(
                    string, pixelSize: annotation.width.textPoints * scale, color: color)
                let topLeft = map.point(origin, bias: .after)
                context.textMatrix = .identity
                for (index, line) in layout.lines.enumerated() {
                    let baseline =
                        Double(topLeft.y) + Double(layout.ascent)
                        + Double(index) * Double(layout.lineHeight)
                    context.textPosition = flip.point(CGPoint(x: Double(topLeft.x), y: baseline))
                    CTLineDraw(line, context)
                }
            case .blur:
                break
            }
            context.restoreGState()
        }
    }
}
