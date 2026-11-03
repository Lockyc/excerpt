import CoreGraphics
import CoreText
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct TextMatcherTests {
    static let white = RGBA(r: 255, g: 255, b: 255, a: 255)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 255)
    static let slate = RGBA(r: 0x27, g: 0x2C, b: 0x35, a: 255)
    static let gridline = RGBA(r: 0x45, g: 0x4B, b: 0x56, a: 255)

    /// A text drawn through Core's renderer onto `ground`, and the run a recogniser would report
    /// for it: the ink's box padded by 2px.
    struct Fixture {
        let buffer: PixelBuffer
        let run: RecognizedText
        /// Where the renderer put the text's baseline, in pixels.
        let baseline: Double
    }

    static func fixture(
        _ string: String, style: TextStyle, color: RGBA, at origin: CGPoint, scale: Double,
        ground: CGImage
    ) -> Fixture {
        let text = Annotation(
            id: 1, shape: .text(origin: origin, string: string, style: style),
            color: .sampled(color))
        let edits = EditDocument(scale: scale, annotations: [text])
        let out = PixelBuffer(Renderer.render(ground, edits: edits).image)
        let plain = PixelBuffer(ground)
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
        for y in 0..<out.height {
            for x in 0..<out.width where out[x: x, y: y] != plain[x: x, y: y] {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let ascent = CTFontGetAscent(
            TextLayout.font(pixelSize: style.points * scale, font: style.font, bold: style.bold))
        return Fixture(
            buffer: out, run: RecognizedText(string, box.insetBy(dx: -2, dy: -2)),
            baseline: Double(origin.y) + Double(ascent))
    }

    /// `match` recovers the style, colour and baseline the fixture was drawn with.
    static func expectRoundTrip(
        _ string: String, style: TextStyle, color: RGBA, at origin: CGPoint, scale: Double,
        ground: CGImage
    ) throws {
        let f = fixture(
            string, style: style, color: color, at: origin, scale: scale, ground: ground)
        let matched = try #require(TextMatcher.match(f.run, in: f.buffer, scale: scale))
        // The ink's box: within what the renderer changed, short of it by at most a faint edge.
        let drawn = f.run.bounds.insetBy(dx: 2, dy: 2)
        #expect(drawn.contains(matched.ink), "ink \(matched.ink) vs \(drawn)")
        #expect(matched.ink.insetBy(dx: -2, dy: -2).contains(drawn), "ink \(matched.ink)")
        #expect(abs(matched.style.points - style.points) <= 0.5, "points \(matched.style.points)")
        #expect(matched.style.bold == style.bold)
        #expect(matched.style.font == style.font)
        #expect(matched.style.alignment == style.alignment)
        let ascent = CTFontGetAscent(
            TextLayout.font(
                pixelSize: matched.style.points * scale, font: matched.style.font,
                bold: matched.style.bold))
        let baseline = Double(matched.origin.y) + Double(ascent)
        #expect(abs(baseline - f.baseline) <= 1, "baseline \(baseline) vs \(f.baseline)")
        #expect(
            abs(Double(matched.origin.x) - Double(origin.x)) <= 1,
            "origin.x \(matched.origin.x) vs \(origin.x)")
        let ink = matched.color.rgba
        for (a, b) in [(ink.r, color.r), (ink.g, color.g), (ink.b, color.b)] {
            #expect(abs(Int(a) - Int(b)) <= 8, "colour \(ink) vs \(color)")
        }
    }

    static func plain(_ color: RGBA, width: Int = 400, height: Int = 120) -> CGImage {
        Fixtures.paint(width: width, height: height) { _, _ in color }
    }

    /// Dark cells 160px wide and 40px tall between 1px gridlines.
    static func grid(width: Int = 480, height: Int = 121) -> CGImage {
        Fixtures.paint(width: width, height: height) { x, y in
            x % 160 == 0 || y % 40 == 0 ? gridline : slate
        }
    }

    @Test func sansRegular14() throws {
        try Self.expectRoundTrip(
            "Quarterly totals 2026", style: TextStyle(points: 14, bold: false),
            color: RGBA(r: 0x33, g: 0x33, b: 0x33, a: 255), at: CGPoint(x: 20, y: 40), scale: 1,
            ground: Self.plain(RGBA(r: 0xF4, g: 0xF4, b: 0xF6, a: 255)))
    }

    @Test func monoBold7AtRetina() throws {
        try Self.expectRoundTrip(
            "SELECT id FROM users", style: TextStyle(points: 7, bold: true, font: .mono),
            color: RGBA(r: 0x1F, g: 0x4E, b: 0xB4, a: 255), at: CGPoint(x: 30, y: 50), scale: 2,
            ground: Self.plain(Self.white))
    }

    @Test func whiteOnSlateCentredInAGriddedCell() throws {
        try Self.expectRoundTrip(
            "Revenue", style: TextStyle(points: 13, bold: true, alignment: .centered),
            color: Self.white, at: CGPoint(x: 240, y: 52), scale: 1, ground: Self.grid())
    }

    @Test func blackOnWhiteLeft() throws {
        try Self.expectRoundTrip(
            "git commit --amend", style: TextStyle(points: 12, bold: false, font: .mono),
            color: Self.black, at: CGPoint(x: 16, y: 30), scale: 2,
            ground: Self.plain(Self.white, width: 600, height: 160))
    }

    /// A wide left side-bearing: the ink starts well right of the glyph origin.
    @Test func monoBoldNameLeft() throws {
        try Self.expectRoundTrip(
            "Lachlan", style: TextStyle(points: 13, bold: true, font: .mono),
            color: Self.white, at: CGPoint(x: 40, y: 50), scale: 2,
            ground: Self.plain(Self.slate))
    }

    /// No ground beside the run on either side — its ink spans the whole buffer — so there is no
    /// region to be centred in: the text is left-aligned.
    @Test func aRunWithNoGroundBesideItIsLeft() throws {
        let f = Self.fixture(
            "Revenue", style: TextStyle(points: 13, bold: true), color: Self.white,
            at: CGPoint(x: 40, y: 30), scale: 1, ground: Self.plain(Self.slate))
        let drawn = f.run.bounds.insetBy(dx: 2, dy: 2)
        let strip = try #require(
            f.buffer.makeImage().cropping(
                to: CGRect(x: drawn.minX, y: 0, width: drawn.width, height: 120)))
        let run = RecognizedText(f.run.string, f.run.bounds.offsetBy(dx: -drawn.minX, dy: 0))
        let matched = try #require(TextMatcher.match(run, in: PixelBuffer(strip), scale: 1))
        #expect(matched.style.alignment == .left)
    }

    @Test func noInkIsNil() {
        let buffer = PixelBuffer(Self.plain(Self.white))
        let run = RecognizedText("nothing", CGRect(x: 20, y: 20, width: 100, height: 20))
        #expect(TextMatcher.match(run, in: buffer, scale: 1) == nil)
    }

    @Test func aBoxOutsideTheBufferIsNil() {
        let buffer = PixelBuffer(Self.plain(Self.white))
        let run = RecognizedText("away", CGRect(x: 900, y: 900, width: 100, height: 20))
        #expect(TextMatcher.match(run, in: buffer, scale: 1) == nil)
    }
}
