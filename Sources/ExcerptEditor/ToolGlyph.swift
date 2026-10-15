import AppKit

/// Each tool's glyph, on the toolbar and badged on the canvas cursor.
@MainActor
enum ToolGlyph {
    /// The tool's glyph as a template image at `pointSize`.
    static func image(_ tool: Tool, pointSize: CGFloat) -> NSImage? {
        guard let symbol = tool.symbol else { return drawn(tool, pointSize: pointSize) }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: tool.title)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }

    /// The toolbar's segment image: the glyph, with the tool's key in the bottom-right corner.
    static func keyed(_ tool: Tool, pointSize: CGFloat) -> NSImage? {
        guard let glyph = image(tool, pointSize: pointSize) else { return nil }
        let key = NSAttributedString(
            string: tool.key.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: pointSize * 0.55, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
        let keySize = key.size()
        let side = pointSize * 1.5
        let size = CGSize(width: side + keySize.width * 0.75, height: side)
        let image = NSImage(size: size, flipped: true) { _ in
            glyph.draw(
                in: CGRect(
                    x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2,
                    width: glyph.size.width, height: glyph.size.height))
            key.draw(
                at: CGPoint(x: size.width - keySize.width, y: size.height - keySize.height + 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = tool.title
        return image
    }

    /// The tool's glyph from its `svg` source.
    private static func drawn(_ tool: Tool, pointSize: CGFloat) -> NSImage? {
        guard let (source, scale) = svg[tool], let image = NSImage(data: Data(source.utf8))
        else { return nil }
        let side = pointSize * scale
        image.size = CGSize(width: side, height: side)
        image.isTemplate = true
        image.accessibilityDescription = tool.title
        return image
    }

    /// The canvas cursor under `tool`: the arrow to select, the I-beam to type, otherwise a
    /// crosshair badged with the tool's glyph.
    static func cursor(_ tool: Tool) -> NSCursor {
        switch tool {
        case .select: return .arrow
        case .text: return .iBeam
        default:
            if let cached = cursors[tool] { return cached }
            let cursor = badgedCrosshair(tool)
            cursors[tool] = cursor
            return cursor
        }
    }

    private static var cursors: [Tool: NSCursor] = [:]

    /// A white-edged crosshair centred on the hot spot, the glyph below and right of it.
    private static func badgedCrosshair(_ tool: Tool) -> NSCursor {
        let arm: CGFloat = 8
        let size = CGSize(width: 34, height: 34)
        let centre = CGPoint(x: arm + 1, y: arm + 1)
        let glyph = image(tool, pointSize: 11)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: centre.x - arm, y: centre.y))
            cross.addLine(to: CGPoint(x: centre.x + arm, y: centre.y))
            cross.move(to: CGPoint(x: centre.x, y: centre.y - arm))
            cross.addLine(to: CGPoint(x: centre.x, y: centre.y + arm))
            context.setLineCap(.square)
            for (color, width) in [(NSColor.white, 3.0), (NSColor.black, 1.0)] {
                context.addPath(cross)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.strokePath()
            }
            if let glyph {
                let origin = CGPoint(x: centre.x + 5, y: centre.y + 5)
                let frame = CGRect(origin: origin, size: glyph.size)
                let halo = tinted(glyph, .white)
                for dx in [-1.0, 0, 1] {
                    for dy in [-1.0, 0, 1] { halo.draw(in: frame.offsetBy(dx: dx, dy: dy)) }
                }
                tinted(glyph, .black).draw(in: frame)
            }
            return true
        }
        return NSCursor(image: image, hotSpot: centre)
    }

    /// `template` filled with `color`.
    private static func tinted(_ template: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
