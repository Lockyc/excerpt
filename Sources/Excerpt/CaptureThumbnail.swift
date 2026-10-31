import AppKit
import ExcerptCore
import QuickLookThumbnailing

/// A capture's small preview, for the Recent Captures panel.
enum CaptureThumbnail {
    /// A recording's poster frame, as its floating thumbnail shows it, else Quick Look's
    /// thumbnail, fitted and centred in `size`, rendered for a display of `scale` (the backing
    /// scale factor of the screen it shows on); `deliver` runs on the main actor once there is
    /// one, and never when there is none.
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
                deliver(fit(poster, in: size))
            }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            DispatchQueue.main.async {
                let fitted = fit(cgImage, in: size)
                MainActor.assumeIsolated { deliver(fitted) }
            }
        }
    }

    /// The image scaled to fit, centred in a box of `size`.
    nonisolated private static func fit(_ cgImage: CGImage, in size: NSSize) -> NSImage {
        let scale = min(
            size.width / CGFloat(cgImage.width), size.height / CGFloat(cgImage.height))
        let drawn = NSSize(
            width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        let source = NSImage(cgImage: cgImage, size: drawn)
        return NSImage(size: size, flipped: false) { _ in
            source.draw(
                in: NSRect(
                    x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                    width: drawn.width, height: drawn.height))
            return true
        }
    }
}
