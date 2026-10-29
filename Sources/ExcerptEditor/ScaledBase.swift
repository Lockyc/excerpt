import CoreGraphics

/// The canvas's base render resampled to the device pixels it lands on, in tiles, so a repaint
/// copies the tiles it shows instead of resampling the base. A tile holds exactly the pixels
/// drawing the base straight into the context would give there; it is reused while the image
/// and its placement on the device pixel grid hold, and kept only near what is shown. The
/// annotations draw over it in the same context, so their multiply blending reads the base's
/// pixels as it does on export.
final class ScaledBase {
    /// A tile's side in device pixels.
    static let tileSize = 512

    /// What the tiles were drawn for: the image, its size in user space, the user-to-device
    /// scale, where its corner falls within a device pixel, and the interpolation. Translation
    /// by whole device pixels keeps every tile valid, so a tile is placed from `anchor`.
    private struct Placement: Equatable {
        let image: CGImage
        let size: CGSize
        let scale: CGSize
        let phase: CGPoint
        let quality: CGInterpolationQuality

        static func == (a: Placement, b: Placement) -> Bool {
            a.image === b.image && a.size == b.size && a.scale == b.scale && a.phase == b.phase
                && a.quality == b.quality
        }
    }

    private struct Index: Hashable {
        let column: Int
        let row: Int
    }

    private var placement: Placement?
    private var tiles: [Index: CGImage] = [:]
    /// Tiles drawn since the cache was made, for tests.
    private(set) var tilesDrawn = 0

    /// Drops every tile, for a canvas no longer shown.
    func removeAll() {
        placement = nil
        tiles.removeAll()
    }

    /// Draws the part of `image` placed at `rect` that falls in `visible` into `context`, then
    /// drops tiles outside `kept`. All three rects are in the context's user space, which runs
    /// down the image: its first row is at `rect.minY`.
    func draw(
        _ image: CGImage, in rect: CGRect, visible: CGRect, kept: CGRect,
        quality: CGInterpolationQuality, into context: CGContext
    ) {
        let device = context.userSpaceToDeviceSpaceTransform
        guard device.b == 0, device.c == 0 else {
            // Not axis-aligned on the device: there is no pixel grid to cache against.
            Self.paint(image, at: rect, region: visible, quality: quality, into: context)
            return
        }
        let placed = rect.applying(device)
        let anchor = CGPoint(x: placed.minX.rounded(.down), y: placed.minY.rounded(.down))
        let wanted = Placement(
            image: image, size: rect.size, scale: CGSize(width: device.a, height: device.d),
            phase: CGPoint(x: placed.minX - anchor.x, y: placed.minY - anchor.y),
            quality: quality)
        guard wanted == placement else {
            // A new placement is drawn straight in, and tiled from its second repaint on, so one
            // that changes every frame (a live resize, refitting the zoom) costs no more than that.
            placement = wanted
            tiles.removeAll()
            Self.paint(image, at: rect, region: visible, quality: quality, into: context)
            return
        }
        let side = CGFloat(Self.tileSize)
        let extent = CGRect(
            x: anchor.x, y: anchor.y, width: placed.maxX.rounded(.up) - anchor.x,
            height: placed.maxY.rounded(.up) - anchor.y)
        func indices(_ area: CGRect) -> [Index] {
            let shown = area.applying(device).integral.intersection(extent)
            guard !shown.isNull, !shown.isEmpty else { return [] }
            let columns =
                Int(
                    ((shown.minX - anchor.x) / side).rounded(.down))...Int(
                    ((shown.maxX - anchor.x - 1) / side).rounded(.down))
            let rows =
                Int(
                    ((shown.minY - anchor.y) / side).rounded(.down))...Int(
                    ((shown.maxY - anchor.y - 1) / side).rounded(.down))
            return columns.flatMap { column in rows.map { Index(column: column, row: $0) } }
        }
        func frame(_ index: Index) -> CGRect {
            CGRect(
                x: anchor.x + CGFloat(index.column) * side,
                y: anchor.y + CGFloat(index.row) * side, width: side, height: side
            ).intersection(extent)
        }

        let shown = indices(visible)
        let missing = shown.filter { tiles[$0] == nil }
        if let union = missing.map(frame).reduce(nil, { $0?.union($1) ?? $1 }),
            let strip = render(
                image, at: rect, device: device, frame: union, quality: quality, like: context)
        {
            // One render for every tile it lacks, cut into tiles.
            for index in missing {
                tiles[index] = strip.cropping(
                    to: frame(index).offsetBy(dx: -union.minX, dy: -union.minY))
            }
            tilesDrawn += missing.count
        }

        // In device space, whichever way its rows run: a tile's first row is the frame's first.
        context.saveGState()
        context.concatenate(device.inverted())
        context.interpolationQuality = .none
        for index in shown {
            let frame = frame(index)
            guard let tile = tiles[index] else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: frame.minY + frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(tile, in: frame)
            context.restoreGState()
        }
        context.restoreGState()

        let keep = Set(indices(kept))
        tiles = tiles.filter { keep.contains($0.key) }
    }

    /// The device pixels `frame` covers, as drawing `image` at `rect` through `device` gives them;
    /// its first row is the frame's first.
    private func render(
        _ image: CGImage, at rect: CGRect, device: CGAffineTransform, frame: CGRect,
        quality: CGInterpolationQuality, like context: CGContext
    ) -> CGImage? {
        guard
            let space = context.colorSpace ?? image.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB),
            let bitmap = CGContext(
                data: nil, width: Int(frame.width), height: Int(frame.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // The bitmap's device pixels are the frame's, its own device transform undone.
        bitmap.concatenate(
            device.concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
                .concatenating(bitmap.userSpaceToDeviceSpaceTransform.inverted()))
        Self.paint(
            image, at: rect, region: frame.applying(device.inverted()), quality: quality,
            into: bitmap)
        return bitmap.makeImage()
    }

    /// Draws `image` placed at `rect`, clipped to `region`. The whole image, never a crop of it:
    /// CoreGraphics' high-quality resampling of a crop differs from the whole image's well inside
    /// the crop, so tiles drawn from crops would disagree with each other and with export. Each
    /// draw of the whole image has a fixed cost of its own, so `draw` renders the tiles it lacks
    /// in one.
    private static func paint(
        _ image: CGImage, at rect: CGRect, region: CGRect, quality: CGInterpolationQuality,
        into context: CGContext
    ) {
        context.saveGState()
        context.clip(to: region)
        context.interpolationQuality = quality
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}
