import ExcerptCore

/// Synthetic scrolled frames for the stitcher: a long page, sticky bars, an animated element, a
/// form whose rows repeat, and the frames a viewport sees as the page scrolls under it.
public enum ScrollFixtures {
    public static let paper = RGBA(r: 255, g: 255, b: 255, a: 255)
    public static let ink = RGBA(r: 30, g: 30, b: 40, a: 255)

    /// A long page of text-like lines: 14 rows of marks, then 6 blank rows. Each marked row's
    /// pattern comes from a hash of its row index, so no two marked rows are alike.
    public static func page(width: Int, height: Int, seed: UInt64 = 1) -> PixelBuffer {
        paint(width: width, height: height) { x, y in
            guard y % 20 < 14, x >= 4, x < width - 4 else { return paper }
            return mix(seed, UInt64(y), UInt64(x / 2)) % 4 == 0 ? ink : paper
        }
    }

    /// A sticky bar: a tinted band with its own marks, unlike any page row.
    public static func bar(width: Int, height: Int, tone: UInt8) -> PixelBuffer {
        paint(width: width, height: height) { x, y in
            mix(UInt64(tone), UInt64(y), UInt64(x / 4)) % 3 == 0
                ? RGBA(r: tone, g: 40, b: 40, a: 255) : RGBA(r: tone, g: tone, b: 200, a: 255)
        }
    }

    /// A form: fields every `period` rows. Each field is a 10-row label whose marks are unique to
    /// the field, then a box whose 24 inner rows are identical in every field, then blank rows.
    /// Box rows match at any whole number of fields, so an offset one field away from the truth
    /// matches most rows of a small overlap.
    public static func form(width: Int, height: Int, period: Int = 40) -> PixelBuffer {
        precondition(period >= 36, "a field needs its label, box and bottom rule: 36 rows")
        return paint(width: width, height: height) { x, y in
            let field = y / period
            let row = y % period
            switch row {
            case 0..<10:
                guard x >= 4, x < width - 4 else { return paper }
                return mix(99, UInt64(field * 16 + row), UInt64(x / 3)) % 4 == 0 ? ink : paper
            case 10, 35: return x >= 2 && x < width - 2 ? ink : paper
            case 11..<35: return x == 2 || x == width - 3 ? ink : paper
            default: return paper
            }
        }
    }

    /// A list of two-line cards, `period` rows each, `perName` per name: the first line names a
    /// person, the second a slot, so every line repeats down the page (each name `perName` times,
    /// each slot once per name) while no two cards are alike. No row is unique in a viewport
    /// holding more than a name's worth of cards.
    public static func cards(width: Int, count: Int, period: Int = 40, perName: Int = 6)
        -> PixelBuffer
    {
        precondition(period >= 30, "a card needs two lines and a gap: 30 rows")
        let pink = RGBA(r: 252, g: 232, b: 232, a: 255)
        return paint(width: width, height: count * period) { x, y in
            let card = y / period
            let row = y % period
            guard row < period - 6 else { return paper }
            guard x >= 8, x < width - 4 else { return x < 4 ? ink : pink }
            let line: UInt64
            switch row {
            case 4..<12: line = UInt64(card / perName)
            case 16..<24: line = 1000 + UInt64(card % perName)
            default: return pink
            }
            return mix(line, UInt64(row % 4), UInt64(x / 3)) % 3 == 0 ? ink : pink
        }
    }

    /// Rows that repeat every `period` rows with nothing unique: offsets a whole number of periods
    /// apart are indistinguishable.
    public static func stripes(width: Int, height: Int, period: Int = 30) -> PixelBuffer {
        paint(width: width, height: height) { x, y in
            mix(7, UInt64(y % period), UInt64(x / 3)) % 3 == 0 ? ink : paper
        }
    }

    /// What a viewport `viewport` rows tall sees with the page scrolled to `offset`, under an
    /// optional sticky header and over an optional sticky footer.
    public static func frame(
        _ page: PixelBuffer, offset: Int, viewport: Int, header: PixelBuffer? = nil,
        footer: PixelBuffer? = nil
    ) -> PixelBuffer {
        precondition(
            offset >= 0 && viewport > 0 && offset + viewport <= page.height,
            "the viewport must lie inside the page")
        precondition(
            (header?.height ?? 0) + (footer?.height ?? 0) <= viewport,
            "header and footer must fit in the viewport")
        var view = rows(page, offset..<(offset + viewport))
        if let header { view = overlay(view, header, atRow: 0) }
        if let footer { view = overlay(view, footer, atRow: viewport - footer.height) }
        return view
    }

    /// `buffer` with a `width` by `height` block at (`x`, `y`) painted in a pattern that changes
    /// with `phase`: a spinner, a blinking caret, a video.
    public static func animated(
        _ buffer: PixelBuffer, x: Int, y: Int, width: Int, height: Int, phase: Int
    ) -> PixelBuffer {
        var out = buffer
        for row in y..<(y + height) {
            for column in x..<(x + width) {
                let v = UInt8(truncatingIfNeeded: mix(UInt64(phase), UInt64(row), UInt64(column)))
                set(&out, column, row, RGBA(r: v, g: v &+ 80, b: 120, a: 255))
            }
        }
        return out
    }

    /// `buffer` with the rows of `top` painted over it from `atRow`.
    public static func overlay(_ buffer: PixelBuffer, _ top: PixelBuffer, atRow: Int) -> PixelBuffer
    {
        precondition(top.width == buffer.width, "overlay width must match")
        precondition(
            atRow >= 0 && atRow + top.height <= buffer.height, "overlay must lie inside the buffer")
        var out = buffer
        let rowBytes = buffer.width * 4
        out.bytes.replaceSubrange(
            (atRow * rowBytes)..<((atRow + top.height) * rowBytes), with: top.bytes)
        return out
    }

    /// `left` and `right` side by side.
    public static func beside(_ left: PixelBuffer, _ right: PixelBuffer) -> PixelBuffer {
        precondition(left.height == right.height)
        return paint(width: left.width + right.width, height: left.height) { x, y in
            x < left.width ? left[x: x, y: y] : right[x: x - left.width, y: y]
        }
    }

    /// `buffer` over a faint pattern fixed to the viewport, not the page, showing through its
    /// paper: a chat app's doodle wallpaper behind the messages.
    public static func wallpapered(_ buffer: PixelBuffer) -> PixelBuffer {
        paint(width: buffer.width, height: buffer.height) { x, y in
            let c = buffer[x: x, y: y]
            guard c == paper, mix(5, UInt64(y), UInt64(x)) % 4 == 0 else { return c }
            return RGBA(r: 243, g: 244, b: 246, a: 255)
        }
    }

    /// `buffer` with an overlay scroll bar's thumb: a dark band `width` columns wide against the
    /// right edge, from row `y` for `height` rows.
    public static func thumb(
        _ buffer: PixelBuffer, y: Int, height: Int, width: Int = 6
    ) -> PixelBuffer {
        var out = buffer
        for row in y..<(y + height) {
            for column in (buffer.width - width)..<buffer.width {
                set(&out, column, row, RGBA(r: 90, g: 90, b: 90, a: 255))
            }
        }
        return out
    }

    /// `frame` cut to a window's shape: a rounded rect of `radius` whose pixels outside it, or
    /// only partly inside (the corners' anti-aliased rim), are clear, alpha 0 and colour 0; and
    /// the shape's pixels within `edge` of its outline across or down half transparent,
    /// alpha 128 and premultiplied, as a window's border is.
    public static func windowShaped(_ frame: PixelBuffer, radius: Int, edge: Int) -> PixelBuffer {
        let w = frame.width
        let h = frame.height
        func inside(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < w, y >= 0, y < h else { return false }
            // Every corner of the pixel lies in the rounded rect.
            for (cx, cy) in [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)] {
                let dx = max(radius - cx, cx - (w - radius), 0)
                let dy = max(radius - cy, cy - (h - radius), 0)
                if dx * dx + dy * dy > radius * radius { return false }
            }
            return true
        }
        return paint(width: w, height: h) { x, y in
            guard inside(x, y) else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
            let c = frame[x: x, y: y]
            let border =
                edge > 0
                && (1...edge).contains { d in
                    !inside(x - d, y) || !inside(x + d, y) || !inside(x, y - d)
                        || !inside(x, y + d)
                }
            guard border else { return c }
            func half(_ v: UInt8) -> UInt8 { UInt8(Int(v) * 128 / 255) }
            return RGBA(r: half(c.r), g: half(c.g), b: half(c.b), a: 128)
        }
    }

    public static func rows(_ buffer: PixelBuffer, _ range: Range<Int>) -> PixelBuffer {
        let rowBytes = buffer.width * 4
        return PixelBuffer(
            width: buffer.width, height: range.count,
            bytes: Array(
                buffer.bytes[(range.lowerBound * rowBytes)..<(range.upperBound * rowBytes)]))
    }

    public static func columns(_ buffer: PixelBuffer, _ range: Range<Int>) -> PixelBuffer {
        paint(width: range.count, height: buffer.height) { x, y in
            buffer[x: range.lowerBound + x, y: y]
        }
    }

    public static func stack(_ parts: [PixelBuffer]) -> PixelBuffer {
        precondition(!parts.isEmpty, "nothing to stack")
        precondition(parts.allSatisfy { $0.width == parts[0].width }, "stacked widths must match")
        return PixelBuffer(
            width: parts[0].width, height: parts.reduce(0) { $0 + $1.height },
            bytes: parts.flatMap(\.bytes))
    }

    public static func paint(width: Int, height: Int, _ color: (Int, Int) -> RGBA) -> PixelBuffer {
        var buffer = PixelBuffer(
            width: width, height: height, bytes: [UInt8](repeating: 0, count: width * height * 4))
        for y in 0..<height {
            for x in 0..<width { set(&buffer, x, y, color(x, y)) }
        }
        return buffer
    }

    static func set(_ buffer: inout PixelBuffer, _ x: Int, _ y: Int, _ c: RGBA) {
        let i = (y * buffer.width + x) * 4
        buffer.bytes[i] = c.r
        buffer.bytes[i + 1] = c.g
        buffer.bytes[i + 2] = c.b
        buffer.bytes[i + 3] = c.a
    }

    /// SplitMix64 over three inputs: a stable pseudo-random pattern.
    public static func mix(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64 {
        var z =
            a &* 0x9E37_79B9_7F4A_7C15 &+ b &* 0xBF58_476D_1CE4_E5B9 &+ c &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
