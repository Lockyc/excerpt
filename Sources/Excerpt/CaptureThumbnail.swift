import AppKit
import ExcerptCore

/// A capture's small preview, for the Recent Captures panel.
enum CaptureThumbnail {
    /// A recording's poster frame, as its floating thumbnail shows it, else the image's rows that
    /// show in the tile, placed in `size` where `RecentLayout.thumbnailFrame` puts them, rendered for
    /// a display of `scale` (the backing scale factor of the screen it shows on); `deliver` runs on
    /// the main actor once there is one, and never when there is none.
    @MainActor
    static func load(
        _ url: URL, size: NSSize, scale: CGFloat,
        deliver: @escaping @MainActor (NSImage) -> Void
    ) {
        if LibraryNaming.isRecording(url) {
            let longest = Int((max(size.width, size.height) * scale).rounded(.up))
            Task { @MainActor in
                guard
                    let poster = await RecordingPoster.firstFrame(
                        of: url, maximumPixelSize: longest)
                else { return }
                let pixels = CGSize(width: poster.width, height: poster.height)
                // The poster is already no larger than the tile, so it is drawn whole and clipped.
                let frame = RecentLayout.thumbnailFrame(pixels: pixels, tile: size, scale: scale)
                deliver(fit(poster, at: frame, in: size))
            }
            return
        }
        // Off the main thread: reading a library in iCloud Drive can download an evicted file
        // first, which would hang the panel.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let (image, frame) = still(url, tile: size, scale: scale) else { return }
            DispatchQueue.main.async {
                let fitted = fit(image, at: frame, in: size)
                MainActor.assumeIsolated { deliver(fitted) }
            }
        }
    }

    /// The image's rows that show in a tile of `tile` points at `scale`, decoded at the size they
    /// draw, and where they draw; nil when the file isn't an image ImageIO reads.
    nonisolated private static func still(_ url: URL, tile: CGSize, scale: CGFloat) -> (
        CGImage, CGRect
    )? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
            let pixels = ThumbnailDecoder.pixelSize(of: data)
        else { return nil }
        let shown = RecentLayout.thumbnailRows(pixels: pixels, tile: tile, scale: scale)
        let width = Int((shown.frame.width * scale).rounded(.up))
        guard let image = ThumbnailDecoder.topRows(of: data, rows: shown.rows, width: width)
        else { return nil }
        return (image, shown.frame)
    }

    /// The image drawn at `frame` in a box of `size`, cropped to the box.
    nonisolated private static func fit(_ cgImage: CGImage, at frame: CGRect, in size: NSSize)
        -> NSImage
    {
        let source = NSImage(cgImage: cgImage, size: frame.size)
        return NSImage(size: size, flipped: false) { bounds in
            NSBezierPath.clip(bounds)
            source.draw(in: frame)
            return true
        }
    }
}
