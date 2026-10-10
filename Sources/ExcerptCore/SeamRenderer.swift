import CoreGraphics

public enum SeamRenderer {
    /// Removes `bands` (normalised, original pixels) along `axis` and draws each seam: an
    /// `SeamStyle.gapPixels` gap in the gap colour, with both edges torn into the neighbouring
    /// content and stroked with a soft shadow. Labels are drawn by `Renderer`, not here, because
    /// they need the final image geometry.
    public static func removeBands(
        _ image: CGImage, axis: Axis, bands: [Range<Int>], origin: Int = 0, style: SeamStyle,
        scale: Double
    ) -> (image: CGImage, map: AxisMap) {
        let width = image.width
        let height = image.height
        let map = AxisMap(
            extent: axis == .horizontal ? height : width, bands: bands,
            gap: style.gapPixels(scale: scale))
        guard !bands.isEmpty else { return (image, map) }

        let outWidth = axis == .horizontal ? width : map.renderedLength
        let outHeight = axis == .horizontal ? map.renderedLength : height
        let context = PixelBuffer.makeContext(width: outWidth, height: outHeight)
        context.interpolationQuality = .none

        for segment in map.segments {
            let length = segment.source.count
            let source: CGRect
            let destination: CGRect
            switch axis {
            case .horizontal:
                source = CGRect(x: 0, y: segment.source.lowerBound, width: width, height: length)
                destination = CGRect(x: 0, y: segment.destination, width: width, height: length)
            case .vertical:
                source = CGRect(x: segment.source.lowerBound, y: 0, width: length, height: height)
                destination = CGRect(x: segment.destination, y: 0, width: length, height: height)
            }
            if let piece = image.cropping(to: source) {
                context.draw(piece, in: CanvasFlip(height: outHeight).rect(destination))
            }
        }

        let crossLength = Double(axis == .horizontal ? outWidth : outHeight)
        for (gap, band) in zip(map.gaps, bands) {
            var random = SplitMix64(
                state: seed(
                    axis: axis, band: (band.lowerBound + origin)..<(band.upperBound + origin)))
            let before = tornEdge(
                at: Double(gap.destination.lowerBound), inward: -1, crossLength: crossLength,
                axis: axis, style: style, scale: scale, random: &random)
            let after = tornEdge(
                at: Double(gap.destination.upperBound), inward: 1, crossLength: crossLength,
                axis: axis, style: style, scale: scale, random: &random)
            drawSeam(
                before: before, after: after, in: context, canvasHeight: outHeight, style: style,
                scale: scale)
        }
        return (context.makeImage()!, map)
    }

    /// Points along one torn edge, in top-left image coordinates. Each point sits up to the
    /// tear amplitude away from the gap, into the content (`inward` is -1 before the gap, +1
    /// after it).
    static func tornEdge(
        at base: Double, inward: Double, crossLength: Double, axis: Axis, style: SeamStyle,
        scale: Double, random: inout SplitMix64
    ) -> [CGPoint] {
        let step = style.stepPixels(scale: scale)
        let amplitude = style.amplitudePixels(scale: scale)
        var points: [CGPoint] = []
        var t = -step
        while t <= crossLength + step {
            let along = base + inward * random.nextUnit() * amplitude
            points.append(axis == .horizontal ? CGPoint(x: t, y: along) : CGPoint(x: along, y: t))
            t += step
        }
        return points
    }

    static func drawSeam(
        before: [CGPoint], after: [CGPoint], in context: CGContext, canvasHeight: Int,
        style: SeamStyle, scale: Double
    ) {
        let flip = CanvasFlip(height: canvasHeight).point
        let fill = CGMutablePath()
        fill.addLines(between: (before + after.reversed()).map(flip))
        fill.closeSubpath()
        context.addPath(fill)
        context.setFillColor(style.gapColor.cgColor)
        context.fillPath()

        context.saveGState()
        context.setShadow(
            offset: .zero, blur: CGFloat(2 * scale), color: CGColor(gray: 0, alpha: 0.35))
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        context.setLineWidth(CGFloat(scale))
        context.setLineJoin(.round)
        for edge in [before, after] {
            let path = CGMutablePath()
            path.addLines(between: edge.map(flip))
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    static func seed(axis: Axis, band: Range<Int>) -> UInt64 {
        let axisBits: UInt64 = axis == .horizontal ? 0x68 : 0x76
        return axisBits << 56 ^ UInt64(band.lowerBound) << 28 ^ UInt64(band.upperBound)
    }
}
