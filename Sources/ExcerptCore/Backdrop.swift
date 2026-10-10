import CoreGraphics

public enum Backdrop {
    /// A window capture centred on a plain backdrop with `padding` pixels on every side
    /// (negative reads as 0).
    public static func compose(_ image: CGImage, padding requested: Int, color: RGBA) -> CGImage {
        let padding = max(0, requested)
        let width = image.width + 2 * padding
        let height = image.height + 2 * padding
        let context = PixelBuffer.makeContext(width: width, height: height)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(
            image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
        return context.makeImage()!
    }
}
