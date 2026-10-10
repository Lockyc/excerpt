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
        // A label sits mid-way along the longest kept stretch of the other axis, so a row
        // label and a column label never land on the point where the two seams cross.
        let columnCentre = labelCentre(of: columns)
        let rowCentre = labelCentre(of: rows)
        for gap in rows.gaps {
            let mid = Double(gap.destination.lowerBound + gap.destination.upperBound) / 2
            SeamLabel.draw(
                SeamLabel.text(removedPixels: gap.removed, scale: edits.scale),
                center: CGPoint(x: columnCentre, y: mid), vertical: false, in: context,
                canvasHeight: height, scale: edits.scale)
        }
        for gap in columns.gaps {
            let mid = Double(gap.destination.lowerBound + gap.destination.upperBound) / 2
            SeamLabel.draw(
                SeamLabel.text(removedPixels: gap.removed, scale: edits.scale),
                center: CGPoint(x: mid, y: rowCentre), vertical: true, in: context,
                canvasHeight: height, scale: edits.scale)
        }
        return RenderResult(image: context.makeImage()!, rows: rows, columns: columns)
    }

    /// Midpoint, in rendered coordinates, of the largest kept segment of `map`.
    private static func labelCentre(of map: AxisMap) -> Double {
        guard let largest = map.segments.max(by: { $0.source.count < $1.source.count }) else {
            return Double(map.renderedLength) / 2
        }
        return Double(largest.destination) + Double(largest.source.count) / 2
    }
}
