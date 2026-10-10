import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
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
            plain.image, map: plain.map, scale: 2, recognizer: VisionTextRecognizer())
        #expect(plainText.contains("hunter2"))
        #expect(plainText.contains("swordfish"))
        let edits = EditDocument(
            scale: 2,
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 0, y: 112, width: 840, height: 56)))
            ], salt: 7)
        let render = Renderer.render(image, edits: edits)
        let text = try CaptureText.read(
            render.image, map: render.map, scale: 2, recognizer: VisionTextRecognizer())
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

    static func read(_ image: CGImage, scale: Double, blur: CGRect?) throws -> String {
        let edits = EditDocument(
            scale: scale,
            annotations: blur.map { [Annotation(id: 1, shape: .blur(rect: $0))] } ?? [], salt: 7)
        let render = Renderer.render(image, edits: edits)
        return try CaptureText.read(
            render.image, map: render.map, scale: scale, recognizer: VisionTextRecognizer())
    }

    @Test(
        .timeLimit(.minutes(3)),
        arguments: [64.0, 80.0, 120.0], [1.0, 2.0])
    func aBlurredLineOfAnySizeIsUnreadable(fontSize: Double, scale: Double) throws {
        let (image, blur) = Self.line(fontSize: fontSize, scale: scale)
        // Positive control: unblurred, the line is read, so its absence below is the blur's
        // doing and not a font or model miss.
        let plain = try Self.read(image, scale: scale, blur: nil)
        #expect(plain.contains("4729"), "\(fontSize)pt at \(scale)×: \(plain)")
        let text = try Self.read(image, scale: scale, blur: blur)
        let upper = text.uppercased()
        #expect(!upper.contains("TOKEN"), "\(fontSize)pt at \(scale)×: \(text)")
        #expect(!upper.contains("KEY"), "\(fontSize)pt at \(scale)×: \(text)")
        for digit in "4729" {
            #expect(!text.contains(digit), "\(fontSize)pt at \(scale)×: \(text)")
        }
    }
}
