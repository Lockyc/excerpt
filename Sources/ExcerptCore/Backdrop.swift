import CoreGraphics

public enum Backdrop {
    public enum Fill {
        case color(RGBA)
        /// The image scaled to cover the whole canvas, cropped evenly about its centre; the
        /// capture casts a soft shadow onto it.
        case image(CGImage)
    }

    /// A window capture centred on a backdrop with `padding` pixels on every side (negative
    /// reads as 0).
    public static func compose(_ image: CGImage, padding requested: Int, fill: Fill) -> CGImage {
        let padding = max(0, requested)
        let width = image.width + 2 * padding
        let height = image.height + 2 * padding
        let context = PixelBuffer.makeContext(width: width, height: height)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let frame = CGRect(x: padding, y: padding, width: image.width, height: image.height)
        switch fill {
        case .color(let color):
            context.setFillColor(color.cgColor)
            context.fill(canvas)
        case .image(let backdrop):
            context.interpolationQuality = .high
            context.draw(
                backdrop,
                in: aspectFill(
                    CGSize(width: backdrop.width, height: backdrop.height), into: canvas.size))
            let p = CGFloat(padding)
            context.setShadow(
                offset: CGSize(width: 0, height: -p * 0.15), blur: p * 0.5,
                color: CGColor(gray: 0, alpha: 0.4))
        }
        context.interpolationQuality = .none
        context.draw(image, in: frame)
        return context.makeImage()!
    }

    /// The rect, in canvas coordinates, that `source` is drawn into to cover `canvas` with its
    /// aspect ratio kept and the overflow split evenly between opposite edges.
    static func aspectFill(_ source: CGSize, into canvas: CGSize) -> CGRect {
        let scale = max(canvas.width / source.width, canvas.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}
