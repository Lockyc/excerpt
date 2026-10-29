import CoreGraphics
import CoreText
import ExcerptCore
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptExport

@Suite struct VisionTextRecognizerTests {
    @Test func boundingBoxesTurnIntoTopLeftPixels() {
        let rect = VisionTextRecognizer.pixelRect(
            normalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), width: 400, height: 200)
        #expect(rect == CGRect(x: 100, y: 50, width: 200, height: 50))
    }

    /// A real recognition pass over drawn text: the words come back in reading order, and the
    /// line under a blur does not come back at all. The first run after login compiles Vision's
    /// recognition model (about 38 s); later runs are fast. The limit allows for the first.
    @Test(.timeLimit(.minutes(3))) func readsDrawnTextButNotBlurredText() throws {
        let image = TextFixtures.page(
            [
                "Quarterly revenue report", "Northwind Traders 4821", "Password hunter2 swordfish",
                "Totals carried forward",
            ], width: 420)
        // Positive control: unblurred, the secret line is read, so its absence below is the blur's
        // doing and not a font or model miss.
        let plain = Renderer.render(image, edits: EditDocument(scale: 2, annotations: [], salt: 7))
        let plainText = try CaptureText.read(
            plain.image, scale: 2, recognizer: VisionTextRecognizer())
        #expect(plainText.contains("hunter2"))
        #expect(plainText.contains("swordfish"))
        let edits = EditDocument(
            scale: 2,
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 0, y: 112, width: 840, height: 56)))
            ], salt: 7)
        let render = Renderer.render(image, edits: edits)
        let text = try CaptureText.read(
            render.image, scale: 2, recognizer: VisionTextRecognizer())
        #expect(text.contains("Quarterly revenue report"))
        #expect(text.contains("Northwind Traders 4821"))
        #expect(text.contains("Totals carried forward"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("swordfish"))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(
            lines.firstIndex(of: "Quarterly revenue report")! < lines.firstIndex(
                of: "Totals carried forward")!)
    }
}

/// Large text under a blur, read by real Vision: a blur's blocks grow with the rect it covers,
/// so a line drawn at any size stays unreadable. Each line is blurred by a rect barely taller
/// than its glyphs, the tightest a user would draw.
@Suite struct LargeTextBlurTests {
    static let secret = "TOKEN 4729 KEY"

    static func line(fontSize: Double, scale: Double) -> (image: CGImage, blur: CGRect) {
        let lineHeight = Int(fontSize * 1.4)
        let width = Int(fontSize * 11)
        let image = TextFixtures.page(
            [secret], width: width, lineHeight: lineHeight, fontSize: fontSize, scale: scale)
        let baseline = 0.75 * Double(lineHeight)
        let blur = CGRect(
            x: 6 * scale, y: (baseline - 0.85 * fontSize) * scale,
            width: Double(width - 12) * scale, height: 1.05 * fontSize * scale)
        return (image, blur)
    }

    static func read(_ image: CGImage, scale: Double, blurs: [CGRect]) throws -> String {
        let edits = EditDocument(
            scale: scale,
            annotations: blurs.enumerated().map { Annotation(id: $0 + 1, shape: .blur(rect: $1)) },
            salt: 7)
        let render = Renderer.render(image, edits: edits)
        return try CaptureText.read(
            render.image, scale: scale, recognizer: VisionTextRecognizer())
    }

    @Test(
        .timeLimit(.minutes(3)),
        arguments: [64.0, 80.0, 120.0], [1.0, 2.0])
    func aBlurredLineOfAnySizeIsUnreadable(fontSize: Double, scale: Double) throws {
        let (image, blur) = Self.line(fontSize: fontSize, scale: scale)
        // Positive control: unblurred, the line is read, so its absence below is the blur's
        // doing and not a font or model miss.
        let plain = try Self.read(image, scale: scale, blurs: [])
        #expect(plain.contains("4729"), "\(fontSize)pt at \(scale)×: \(plain)")
        let text = try Self.read(image, scale: scale, blurs: [blur])
        Self.expectUnreadable(text, "\(fontSize)pt at \(scale)×")
    }

    static func expectUnreadable(_ text: String, _ label: String) {
        let upper = text.uppercased()
        #expect(!upper.contains("TOKEN"), "\(label): \(text)")
        #expect(!upper.contains("KEY"), "\(label): \(text)")
        for digit in "4729" { #expect(!text.contains(digit), "\(label): \(text)") }
    }

    /// The same tight cover drawn as several blurs: abutting strips, strips with hairline gaps
    /// between them, or a small blur nested in a large one. Blurs closer than a minimum block are
    /// pixelated as one, so none reads finer than the whole.
    static func layouts(_ cover: CGRect) -> [(String, [CGRect])] {
        func strips(_ count: Int, gap: Double) -> [CGRect] {
            let height = (cover.height - gap * Double(count - 1)) / Double(count)
            return (0..<count).map { i in
                let top = (cover.minY + Double(i) * (height + gap)).rounded()
                let bottom = (cover.minY + Double(i) * (height + gap) + height).rounded()
                return CGRect(x: cover.minX, y: top, width: cover.width, height: bottom - top)
            }
        }
        let abutting = [2, 3, 4, 6].map { ("\($0) strips", strips($0, gap: 0)) }
        let gapped = [4, 6].flatMap { count in
            [1.0, 2.0].map { gap in
                ("\(count) strips \(Int(gap)) px apart", strips(count, gap: gap))
            }
        }
        let small = CGRect(
            x: cover.minX + cover.width * 0.3, y: cover.minY + cover.height * 0.35,
            width: cover.width * 0.3, height: cover.height * 0.3)
        return abutting + gapped + [("nested", [cover, small])]
    }

    @Test(.timeLimit(.minutes(3)), arguments: [1.0, 2.0])
    func touchingBlursOverALargeLineAreUnreadable(scale: Double) throws {
        let (image, cover) = Self.line(fontSize: 120, scale: scale)
        let plain = try Self.read(image, scale: scale, blurs: [])
        #expect(plain.contains("4729"), "120pt at \(scale)×: \(plain)")
        for (name, blurs) in Self.layouts(cover) {
            let text = try Self.read(image, scale: scale, blurs: blurs)
            Self.expectUnreadable(text, "\(name), 120pt at \(scale)×")
        }
    }
}

/// A short, wide selection, one line tall across a wide window: read by real Vision only once
/// the region is padded to a readable shape.
@Suite struct ShortRegionTests {
    @Test(.timeLimit(.minutes(3))) func aShortWideStripIsRead() throws {
        let scale = 2.0
        let (widthPt, heightPt) = (1500, 40)
        let lines: [(String, top: Double, lineHeight: Double)] = [
            ("Footer totals carried forward", 0, 40)
        ]
        let (w, h) = (Int(Double(widthPt) * scale), Int(Double(heightPt) * scale))
        let context = PixelBuffer.makeContext(width: w, height: h)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateUIFontForLanguage(.system, CGFloat(18 * scale), nil)!
        for (text, top, lineHeight) in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(
                x: 30 * scale, y: Double(h) - (top + 0.75 * lineHeight) * scale)
            CTLineDraw(line, context)
        }
        #expect(h < w / 30)
        let text = try CaptureText.read(
            context.makeImage()!, scale: scale, recognizer: VisionTextRecognizer())
        #expect(text == "Footer totals carried forward\n")
    }
}

/// Panes read by real Vision: a menu over a terminal reads pane by pane, and a sheet's shaded
/// row numbers stay on their rows.
@Suite struct PaneReadingTests {
    static func read(_ image: CGImage) throws -> [String] {
        try CaptureText.read(image, scale: 2, recognizer: VisionTextRecognizer())
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test(.timeLimit(.minutes(3))) func aMenuOverATerminalReadsPaneByPane() throws {
        let menu = ["About warden", "Services", "Hide warden", "Hide Others", "Show All"]
        let terminal = [
            "Welcome to the shell", "Type help for commands", "excerpt on dev", "zed launched",
            "build started at noon", "warning timed out", "excerpt on dev", "just run",
            "swift build", "Building for production",
        ]
        let image = TextFixtures.panes(
            [
                .init(
                    x: 0, y: 0, width: 260, height: 240, background: 0.93, lineHeight: 40,
                    lines: menu),
                .init(
                    x: 260, y: 0, width: 360, height: 240, background: 0.12, ink: 0.9,
                    lineHeight: 22, lines: terminal),
            ], width: 620, height: 240)
        let lines = try Self.read(image)
        #expect(lines.filter { !$0.isEmpty } == menu + terminal)
    }

    @Test(.timeLimit(.minutes(3))) func shadedRowNumbersStayOnTheirRows() throws {
        let numbers = ["101", "102", "103", "104"]
        let cells = ["Northwind 4821", "Contoso 1290", "Fabrikam 7730", "Litware 5104"]
        let image = TextFixtures.panes(
            [
                .init(x: 0, y: 0, width: 80, height: 112, background: 0.85, lines: numbers),
                .init(x: 80, y: 0, width: 400, height: 112, lines: cells),
            ], width: 480, height: 112)
        let lines = try Self.read(image)
        #expect(lines.filter { !$0.isEmpty } == zip(numbers, cells).map { "\($0) \($1)" })
    }
}
