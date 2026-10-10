import CoreGraphics

@testable import ExcerptCore

enum Fixtures {
    /// Row y has a colour no other row shares (for y < 251²), so a test can tell exactly which
    /// source row landed where.
    static func rowColor(_ y: Int) -> RGBA {
        RGBA(r: UInt8(y % 251), g: UInt8((y / 251) % 251), b: 90, a: 255)
    }

    static func rowStripes(width: Int, height: Int) -> CGImage {
        paint(width: width, height: height) { _, y in rowColor(y) }
    }

    static func columnStripes(width: Int, height: Int) -> CGImage {
        paint(width: width, height: height) { x, _ in rowColor(x) }
    }

    /// A spreadsheet-like grid: 1px grey gridlines at `y % rowHeight == 0` and `x % 60 == 0`,
    /// white cells, and a coloured block in rows `4..<16` (mod 20) of every third cell column.
    /// The gridlines cross every other line, so the only uniform rows and columns are gridlines.
    static func sheet(width: Int, height: Int, rowHeight: Int = 20) -> CGImage {
        paint(width: width, height: height) { x, y in
            if y % rowHeight == 0 || x % 60 == 0 { return RGBA(r: 200, g: 200, b: 205, a: 255) }
            let inBlockRows = (4..<16).contains(y % rowHeight)
            let inBlockCols = (x / 60) % 3 == 1 && (10..<50).contains(x % 60)
            if inBlockRows && inBlockCols { return RGBA(r: 40, g: 110, b: 220, a: 255) }
            return RGBA(r: 255, g: 255, b: 255, a: 255)
        }
    }

    static func paint(width: Int, height: Int, _ color: (Int, Int) -> RGBA) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = c.r
                bytes[i + 1] = c.g
                bytes[i + 2] = c.b
                bytes[i + 3] = c.a
            }
        }
        return PixelBuffer(width: width, height: height, bytes: bytes).makeImage()
    }
}
