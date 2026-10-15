import AppKit

/// Each tool's glyph, on the toolbar and badged on the canvas cursor.
@MainActor
enum ToolGlyph {
    /// The tool's glyph as a template image at `pointSize`.
    static func image(_ tool: Tool, pointSize: CGFloat) -> NSImage? {
        guard let symbol = tool.symbol else { return highlight(pointSize: pointSize) }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: tool.title)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }

    /// Three lines of text, the middle one under a highlighter band.
    private static func highlight(pointSize: CGFloat) -> NSImage {
        let unit = pointSize / 16
        let size = CGSize(width: 20 * unit, height: 16 * unit)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            let line = 1.5 * unit
            for (y, width) in [(2.5, 16.0), (12.0, 12.0)] {
                context.fill(CGRect(x: 2 * unit, y: y * unit, width: width * unit, height: line))
            }
            let band = CGRect(x: 0, y: 4.75 * unit, width: size.width, height: 6.5 * unit)
            context.addPath(
                CGPath(
                    roundedRect: band, cornerWidth: 1.5 * unit, cornerHeight: 1.5 * unit,
                    transform: nil))
            context.fillPath()
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 2 * unit, y: 7.25 * unit, width: 14 * unit, height: line))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = Tool.highlight.title
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
