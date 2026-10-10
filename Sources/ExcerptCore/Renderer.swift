import CoreGraphics

public struct RenderResult {
    public let image: CGImage
    /// Original→rendered maps, for placing anything else drawn on the result.
    public let rows: AxisMap
    public let columns: AxisMap
}

/// The one renderer: export writes its output, and the editor draws it.
public enum Renderer {
    /// Removes rows, then columns (column bands are in original x, which row removal leaves
    /// unchanged), then labels every seam on the final geometry.
    public static func render(
        _ original: CGImage, edits: EditDocument, style: SeamStyle = .standard
    ) -> RenderResult {
        let rowBands = CutSet.normalized(edits.cuts, axis: .horizontal, extent: original.height)
        let columnBands = CutSet.normalized(edits.cuts, axis: .vertical, extent: original.width)
        let (afterRows, rows) = SeamRenderer.removeBands(
            original, axis: .horizontal, bands: rowBands, style: style, scale: edits.scale)
        let (afterColumns, columns) = SeamRenderer.removeBands(
            afterRows, axis: .vertical, bands: columnBands, style: style, scale: edits.scale)
        guard !rowBands.isEmpty || !columnBands.isEmpty else {
            return RenderResult(image: original, rows: rows, columns: columns)
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
        return RenderResult(image: context.makeImage()!, rows: rows, columns: columns)
    }

    /// Rendered range of the largest kept segment of `map`; the whole axis when nothing is kept.
    static func largestSegment(of map: AxisMap) -> Range<Double> {
        guard let largest = map.segments.max(by: { $0.source.count < $1.source.count }) else {
            return 0..<Double(map.renderedLength)
        }
        return Double(largest.destination)..<Double(largest.destination + largest.source.count)
    }
}
