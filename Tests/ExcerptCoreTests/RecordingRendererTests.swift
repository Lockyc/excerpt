import CoreGraphics
import Foundation
import Testing

@testable import ExcerptCore

struct RecordingRendererTests {
    /// A 200×120 gradient, with enough structure for blur and overlays to show.
    private func frame() -> CGImage {
        let context = PixelBuffer.makeContext(width: 200, height: 120)
        for x in stride(from: 0, to: 200, by: 10) {
            for y in stride(from: 0, to: 120, by: 10) {
                let shade = CGFloat((x / 10 + y / 10) % 2 == 0 ? 0.85 : 0.6)
                context.setFillColor(CGColor(srgbRed: shade, green: 0.7, blue: 1 - shade, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        return context.makeImage()!
    }

    private func log(_ events: [RecordingEvent], shortcuts: Bool = true) -> RecordingEventLog {
        RecordingEventLog(version: 1, scale: 2, shortcutsLogged: shortcuts, events: events)
    }

    private func edits(
        blurs: [RecordingBlur] = [], shortcuts: Bool = true, clicks: Bool = true
    ) -> RecordingEdits {
        RecordingEdits(
            trim: 0...10, blurs: blurs, showsShortcuts: shortcuts, showsClicks: clicks,
            format: .mp4, blurSalt: 7)
    }

    @Test func pillGolden() throws {
        let image = RecordingRenderer.render(
            frame(), at: 0.5, log: log([.shortcut(time: 0.2, label: "⌘S")]), edits: edits(),
            outputScale: 1)
        try Golden.check(image, named: "recording-pill")
    }

    @Test func ringMidGolden() throws {
        let image = RecordingRenderer.render(
            frame(), at: 0.2, log: log([.click(time: 0, x: 100, y: 40, button: .left)]),
            edits: edits(), outputScale: 1)
        try Golden.check(image, named: "recording-ring-mid")
    }

    @Test func blurSpanGolden() throws {
        let blur = RecordingBlur(rect: CGRect(x: 40, y: 20, width: 80, height: 50), span: 1...2)
        let during = RecordingRenderer.render(
            frame(), at: 1.5, log: log([]), edits: edits(blurs: [blur]), outputScale: 1)
        let outside = RecordingRenderer.render(
            frame(), at: 3, log: log([]), edits: edits(blurs: [blur]), outputScale: 1)
        try Golden.check(during, named: "recording-blur-span")
        #expect(PixelBuffer(outside) == PixelBuffer(frame()))
        #expect(PixelBuffer(during) != PixelBuffer(frame()))
    }

    @Test func togglesOffLeaveTheFrame() {
        let events: [RecordingEvent] = [
            .shortcut(time: 0, label: "⌘S"), .click(time: 0, x: 50, y: 50, button: .right),
        ]
        let image = RecordingRenderer.render(
            frame(), at: 0.1, log: log(events), edits: edits(shortcuts: false, clicks: false),
            outputScale: 1)
        #expect(PixelBuffer(image) == PixelBuffer(frame()))
    }

    @Test func outputScaleHalvesTheSize() {
        let image = RecordingRenderer.render(
            frame(), at: 0, log: log([]), edits: edits(), outputScale: 0.5)
        #expect(image.width == 100)
        #expect(image.height == 60)
    }
}
