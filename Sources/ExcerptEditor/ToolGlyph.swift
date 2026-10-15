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

    /// A highlighter pen over a line, from SVG Repo's `highlighter-svgrepo-com.svg`.
    private static let highlightSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1920"><path fill-rule="evenodd" \
        d="M1809.888 1806.674V1920H110v-113.326h1699.888Zm-1332.35-415.453 143.471 95.647-60.29 \
        93.154H326.816l150.724-188.8ZM616.817 921.94l389.954 260.196-32.75 51.45c-15.753 \
        27.085-46.011 41.364-75.25 36.038-72.754-12.92-146.19 18.359-187.667 80.801l-27.991 \
        41.704-138.825-92.7 27.879-41.818c41.59-62.33 42.497-142.564 \
        2.266-204.213-16.205-24.932-14.506-58.476 3.627-82.388l38.757-49.07Zm678.595-803.027L1537.93 \
        280.74c16.092 10.766 20.399 33.318 11.106 49.523L1067.627 1086.6 687.419 832.864l556.77-703.187c12.466-16.66 \
        35.018-21.532 51.223-10.766ZM312.65 1693.348h309.833l123.186-190.727 59.722-89.414c16.433-24.592 \
        45.104-37.398 72.642-32.185 76.495 14.28 154.123-22.098 192.654-88.394l575.242-903.547c40.344-69.696 \
        20.626-158.657-44.99-202.627l-242.744-161.83c-65.616-43.63-155.37-27.764-203.533 \
        35.585L488.53 901.654c-47.71 62.782-51.336 148.683-8.953 213.506 15.3 23.685 14.62 54.963-1.7 \
        79.668l-58.249 87.26-190.16 238.438c-25.84 32.298-30.712 75.475-12.807 112.646 17.906 \
        37.058 54.737 60.176 95.987 60.176Z"/></svg>
        """

    /// The highlight glyph, its square sized a little over `pointSize` to sit level with the
    /// symbols beside it.
    private static func highlight(pointSize: CGFloat) -> NSImage? {
        guard let image = NSImage(data: Data(highlightSVG.utf8)) else { return nil }
        image.size = CGSize(width: pointSize * 1.125, height: pointSize * 1.125)
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
