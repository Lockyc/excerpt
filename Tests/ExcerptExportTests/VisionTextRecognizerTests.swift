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
