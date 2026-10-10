import AppKit
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

/// The canvas must show what export writes: one renderer.
@MainActor
@Suite struct CanvasViewTests {
    /// The view drawn at one pixel per point, whatever the screen's backing scale.
    func snapshot(_ view: NSView) -> PixelBuffer {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0,
            bitsPerPixel: 0)!
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return PixelBuffer(rep.cgImage!)
    }

    @Test func atFullSizeTheCanvasMatchesTheRender() {
        let document = EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)],
            annotations: [
                Annotation(
                    id: 1,
                    shape: .arrow(tail: CGPoint(x: 40, y: 60), head: CGPoint(x: 300, y: 300)),
                    color: .blue),
                Annotation(
                    id: 2, shape: .text(origin: CGPoint(x: 20, y: 320), string: "Total"),
                    color: .black, width: .thick),
                Annotation(
                    id: 3, shape: .blur(rect: CGRect(x: 200, y: 20, width: 100, height: 60))),
            ])
        let model = EditorModel(original: sheet(), document: document)
        let canvas = CanvasView(model: model)
        canvas.zoom = 1
        let shown = snapshot(canvas)
        let exported = PixelBuffer(Renderer.render(model.original, edits: document).image)
        #expect(shown.width == exported.width && shown.height == exported.height)
        guard shown.width == exported.width, shown.height == exported.height else { return }
        // AppKit's flipped view moves where the rasteriser rounds, so antialiased edges may
        // differ by a few levels; a misplaced or flipped shape differs by far more.
        #expect(shown.fractionDiffering(from: exported, tolerance: 16) <= 0.005)
    }

    func sheet() -> CGImage { Fixtures.sheet(width: 360, height: 400) }

    /// A fit-to-width canvas against the export scaled the same way: shapes land where the
    /// export puts them: measured 0.0001 differing when placed right, 0.011 when one original
    /// pixel off, so the bounds below fail a one-pixel misplacement.
    @Test func aZoomedCanvasMatchesTheScaledRender() {
        let document = zoomedDocument(shift: 0)
        let model = EditorModel(original: sheet(), document: document)
        let canvas = CanvasView(model: model)
        canvas.zoom = 0.5
        let shown = snapshot(canvas)
        let matching = shown.fractionDiffering(
            from: scaledExport(document, by: 0.5), tolerance: 48)
        let misplaced = shown.fractionDiffering(
            from: scaledExport(zoomedDocument(shift: 1), by: 0.5), tolerance: 48)
        #expect(matching <= 0.001)
        #expect(misplaced > 0.005)
    }

    func zoomedDocument(shift: Double) -> EditDocument {
        EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)],
            annotations: [
                Annotation(
                    id: 1,
                    shape: .rectangle(
                        rect: CGRect(x: 40 + shift, y: 250, width: 200, height: 80)),
                    color: .red, width: .thick),
                Annotation(
                    id: 2,
                    shape: .arrow(
                        tail: CGPoint(x: 40, y: 60 + shift), head: CGPoint(x: 300, y: 300)),
                    color: .blue, width: .thick),
            ])
    }

    func scaledExport(_ document: EditDocument, by zoom: CGFloat) -> PixelBuffer {
        let image = Renderer.render(sheet(), edits: document).image
        let width = Int(CGFloat(image.width) * zoom)
        let height = Int(CGFloat(image.height) * zoom)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PixelBuffer(context.makeImage()!)
    }

    @Test func zoomScalesTheCanvasAndTheHitSlop() {
        let model = EditorModel(original: sheet(), document: EditDocument(scale: 2))
        let canvas = CanvasView(model: model)
        canvas.zoom = 0.5
        #expect(canvas.frame.size == CGSize(width: 180, height: 200))
        #expect(model.slop == 12)
    }

    @Test func aBaseChangeReRendersButAnAnnotationChangeDoesNot() {
        let model = EditorModel(original: sheet(), document: EditDocument(scale: 1))
        let canvas = CanvasView(model: model)
        let first = canvas.base.image
        model.apply {
            $0.annotations.append(
                Annotation(
                    id: 1, shape: .rectangle(rect: CGRect(x: 1, y: 1, width: 20, height: 20))))
        }
        canvas.refresh()
        #expect(canvas.base.image === first)
        model.apply { $0.cuts.append(Cut(axis: .horizontal, lower: 100, upper: 200)) }
        canvas.refresh()
        #expect(canvas.base.image !== first)
        #expect(canvas.frame.height == CGFloat(400 - 100 + 18))
    }
}
