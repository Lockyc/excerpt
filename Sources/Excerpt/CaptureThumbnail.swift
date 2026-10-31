import AppKit
import ExcerptCore
import QuickLookThumbnailing

/// A capture's small preview, for the Recent Captures panel.
enum CaptureThumbnail {
    /// A recording's poster frame, as its floating thumbnail shows it, else Quick Look's
    /// thumbnail, placed in `size` as `fit` places it, rendered for a display of `scale` (the
    /// backing scale factor of the screen it shows on); `deliver` runs on the main actor once
    /// there is one, and never when there is none.
    @MainActor
    static func load(
        _ url: URL, size: NSSize, scale: CGFloat,
        deliver: @escaping @MainActor (NSImage) -> Void
    ) {
        if LibraryNaming.recordingExtensions.contains(url.pathExtension.lowercased()) {
            let longest = Int((max(size.width, size.height) * scale).rounded(.up))
            Task { @MainActor in
                guard
                    let poster = await RecordingPoster.firstFrame(
                        of: url, maximumPixelSize: longest)
                else { return }
                deliver(fit(poster, in: size, scale: scale))
            }
            return
        }
        // Quick Look fits its thumbnail inside the size asked for, so it is asked for the size
        // the image will draw at: past the tile for a tall one, the original's for a tiny one.
        let drawn =
            pixelSize(of: url).map {
                RecentLayout.thumbnailFrame(pixels: $0, tile: size, scale: scale).size
            } ?? size
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: drawn, scale: scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            DispatchQueue.main.async {
                let fitted = fit(cgImage, in: size, scale: scale)
                MainActor.assumeIsolated { deliver(fitted) }
            }
        }
    }

    /// The image's pixel size from its header, without decoding it; nil when it isn't an image
    /// ImageIO reads.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The image placed in a box of `size` where `RecentLayout.thumbnailFrame` puts it, cropped
    /// to the box.
    nonisolated private static func fit(_ cgImage: CGImage, in size: NSSize, scale: CGFloat)
        -> NSImage
    {
        let frame = RecentLayout.thumbnailFrame(
            pixels: CGSize(width: cgImage.width, height: cgImage.height), tile: size,
            scale: scale)
        let source = NSImage(cgImage: cgImage, size: frame.size)
        return NSImage(size: size, flipped: false) { bounds in
            NSBezierPath.clip(bounds)
            source.draw(in: frame)
            return true
        }
    }
}
