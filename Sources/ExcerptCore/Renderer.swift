import CoreGraphics

public struct RenderResult {
    public let image: CGImage
    /// Original → rendered placement, for anything else drawn on the result.
    public let map: RenderMap
}

/// The one renderer: export writes its output, and the editor draws it.
public enum Renderer {
    /// Everything below the annotations: blur (from original pixels), then crop, then rows, then
    /// columns (column bands are in original x, which row removal leaves unchanged), then a label
    /// on every seam. The editor caches this stage.
    public static func renderBase(
        _ original: CGImage, edits: EditDocument, style: SeamStyle = .standard
    ) -> RenderResult {
        let full = PixelRect(x: 0, y: 0, width: original.width, height: original.height)
        let crop = edits.crop?.clamped(width: original.width, height: original.height) ?? full
        let blurs = edits.annotations.compactMap { annotation -> CGRect? in
            if case .blur(let rect) = annotation.shape { return rect }
            return nil
        }
        let blurred = BlurRenderer.apply(blurs, to: original, scale: edits.scale)
        let cropped = crop == full ? blurred : blurred.cropping(to: crop.cgRect)!
        let cuts = edits.cuts.map { cut -> Cut in
            let offset = cut.axis == .horizontal ? crop.y : crop.x
            return Cut(axis: cut.axis, lower: cut.lower - offset, upper: cut.upper - offset)
        }
        let rowBands = CutSet.normalized(cuts, axis: .horizontal, extent: crop.height)
        let columnBands = CutSet.normalized(cuts, axis: .vertical, extent: crop.width)
        let (afterRows, rows) = SeamRenderer.removeBands(
            cropped, axis: .horizontal, bands: rowBands, origin: crop.y, style: style,
            scale: edits.scale)
        let (afterColumns, columns) = SeamRenderer.removeBands(
            afterRows, axis: .vertical, bands: columnBands, origin: crop.x, style: style,
            scale: edits.scale)
        let map = RenderMap(crop: crop, rows: rows, columns: columns)
        guard !rowBands.isEmpty || !columnBands.isEmpty else {
            return RenderResult(image: cropped, map: map)
        }

        let width = afterColumns.width
        let height = afterColumns.height
        let context = PixelBuffer.makeContext(width: width, height: height)
        context.draw(afterColumns, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Each label is centred on the largest kept segment of the other axis, then clamped
        // so the pill stays on the canvas (and inside that segment when it fits).
        let columnSegment = largestSegment(of: columns)
        let rowSegment = largestSegment(of: rows)
        let margin = 4 * edits.scale
        for gap in rows.gaps {
            let text = SeamLabel.text(removedPixels: gap.removed, scale: edits.scale)
            let pill = SeamLabel.pillSize(text: text, scale: edits.scale)
            let x = SeamLabel.clampedCentre(
                desired: (columnSegment.lowerBound + columnSegment.upperBound) / 2,
                length: pill.width,
                segment: columnSegment, canvas: Double(width), margin: margin)
            let mid = Double(gap.destination.lowerBound + gap.destination.upperBound) / 2
            SeamLabel.draw(
                text, center: CGPoint(x: x, y: mid), vertical: false, in: context,
                canvasHeight: height, scale: edits.scale)
        }
        for gap in columns.gaps {
            let text = SeamLabel.text(removedPixels: gap.removed, scale: edits.scale)
            let pill = SeamLabel.pillSize(text: text, scale: edits.scale)
            let y = SeamLabel.clampedCentre(
                desired: (rowSegment.lowerBound + rowSegment.upperBound) / 2, length: pill.width,
                segment: rowSegment, canvas: Double(height), margin: margin)
            let mid = Double(gap.destination.lowerBound + gap.destination.upperBound) / 2
            SeamLabel.draw(
                text, center: CGPoint(x: mid, y: y), vertical: true, in: context,
                canvasHeight: height, scale: edits.scale)
        }
        return RenderResult(image: context.makeImage()!, map: map)
    }

    /// The full render that export writes.
    public static func render(
        _ original: CGImage, edits: EditDocument, style: SeamStyle = .standard
    ) -> RenderResult {
        renderBase(original, edits: edits, style: style)
    }

    /// Rendered range of the largest kept segment of `map`; the whole axis when nothing is kept.
    static func largestSegment(of map: AxisMap) -> Range<Double> {
        guard let largest = map.segments.max(by: { $0.source.count < $1.source.count }) else {
            return 0..<Double(map.renderedLength)
        }
        return Double(largest.destination)..<Double(largest.destination + largest.source.count)
    }
}
