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

    @Test func theItemBarFloatsAboveTheSelectionWithItsOptions() {
        let model = EditorModel(
            original: sheet(),
            document: EditDocument(
                scale: 1,
                annotations: [
                    Annotation(
                        id: 1,
                        shape: .rectangle(rect: CGRect(x: 100, y: 200, width: 80, height: 40)))
                ]))
        let canvas = CanvasView(model: model)
        canvas.zoom = 1
        #expect(canvas.itemBarFrame == nil)
        model.selection = .annotation(1)
        guard let bar = canvas.itemBarFrame else {
            Issue.record("no bar")
            return
        }
        #expect(bar.maxY < 200)  // above the rectangle (the canvas is flipped)
        #expect(bar.minX >= 0 && bar.maxX <= canvas.bounds.width)
        // A selection at the very top puts the bar below it.
        model.apply {
            $0.annotations[0].shape = .rectangle(rect: CGRect(x: 100, y: 2, width: 80, height: 40))
        }
        #expect((canvas.itemBarFrame?.minY ?? 0) > 42)
    }

    @Test func typedTextIsDrawnByTheRenderer() {
        let model = EditorModel(original: sheet(), document: EditDocument(scale: 1, salt: 7))
        let canvas = CanvasView(model: model)
        canvas.zoom = 1
        model.tool = .text
        let map = canvas.base.map
        model.beginTyping(at: Pointer(rendered: CGPoint(x: 40, y: 60), map: map), map: map)
        model.updateTyping("Total")
        // The bar and the text view float over the canvas; what is under them is the render.
        for view in canvas.subviews { view.isHidden = true }
        let shown = snapshot(canvas)
        var committed = model.document
        committed.annotations.append(model.typing!)
        let exported = PixelBuffer(Renderer.render(model.original, edits: committed).image)
        #expect(shown.fractionDiffering(from: exported, tolerance: 16) <= 0.005)
    }

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

    @Test func theCanvasFollowsTheModelWithoutBeingTold() {
        let model = EditorModel(original: sheet(), document: EditDocument(scale: 1))
        let canvas = CanvasView(model: model)
        model.apply { $0.cuts.append(Cut(axis: .horizontal, lower: 100, upper: 200)) }
        #expect(canvas.frame.height == CGFloat(400 - 100 + 18))
        model.undo()
        #expect(canvas.frame.height == 400)
        let first = canvas.base.image
        model.apply {
            $0.annotations.append(
                Annotation(
                    id: 1, shape: .blur(rect: CGRect(x: 10, y: 10, width: 60, height: 40))))
        }
        #expect(canvas.base.image !== first)
    }

    @Test func aNonPositiveZoomChangesNothing() {
        let model = EditorModel(original: sheet(), document: EditDocument(scale: 1))
        let canvas = CanvasView(model: model)
        canvas.zoom = 0.5
        canvas.zoom = 0
        #expect(canvas.zoom == 0.5)
        #expect(model.viewScale == 0.5)
    }
}

/// The item bar and the text view as they sit in a window.
@MainActor
@Suite struct ItemBarInWindowTests {
    /// A clipped scroll view over a canvas, in a window, like the editor's.
    func editor(_ document: EditDocument, width: Int = 360, height: Int = 400) -> (
        NSWindow, NSScrollView, CanvasView
    ) {
        let model = EditorModel(
            original: Fixtures.sheet(width: width, height: height), document: document)
        let canvas = CanvasView(model: model)
        canvas.zoom = 1
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = canvas
        window.contentView!.addSubview(scroll)
        return (window, scroll, canvas)
    }

    @Test func aClickOnTheBarNeverReachesTheCanvas() {
        final class Recorder: NSResponder {
            var clicks = 0
            override func mouseDown(with event: NSEvent) { clicks += 1 }
        }
        let bar = ItemBar()
        let recorder = Recorder()
        bar.nextResponder = recorder
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        bar.mouseDown(with: click)  // what a disabled control forwards
        #expect(recorder.clicks == 0)
    }

    @Test func onASmallCaptureTheBarStaysClickable() {
        let (window, _, canvas) = editor(
            EditDocument(
                scale: 1,
                annotations: [
                    Annotation(
                        id: 1,
                        shape: .text(origin: CGPoint(x: 4, y: 4), string: "a", background: true))
                ]),
            width: 100, height: 30)
        canvas.model.selection = .annotation(1)
        guard let bar = canvas.itemBarFrame else {
            Issue.record("no bar")
            return
        }
        #expect(bar.width > canvas.bounds.width)  // wider than the capture itself
        // Every point of the bar hit-tests to the bar, not past it.
        let content = window.contentView!
        for x in [bar.minX + 2, bar.midX, bar.maxX - 2] {
            let point = content.convert(CGPoint(x: x, y: bar.midY), from: canvas)
            let hit = content.hitTest(point)
            #expect(hit != nil && hit!.isDescendant(of: canvas.itemBarView))
        }
    }

    @Test func deletingWhileTypingHandsTheKeysBackToTheCanvas() {
        let (window, _, canvas) = editor(EditDocument(scale: 1, salt: 7))
        canvas.model.tool = .text
        let map = canvas.base.map
        canvas.beginText(at: Pointer(rendered: CGPoint(x: 40, y: 60), map: map))
        #expect(window.firstResponder is NSTextView)
        canvas.deleteItem()
        #expect(window.firstResponder === canvas)
    }

    @Test func typingLeavesNothingOnTheWindowsUndo() {
        let (window, _, canvas) = editor(EditDocument(scale: 1, salt: 7))
        canvas.model.tool = .text
        let map = canvas.base.map
        canvas.beginText(at: Pointer(rendered: CGPoint(x: 40, y: 60), map: map))
        (window.firstResponder as? NSTextView)?.insertText(
            "abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.commitInProgress()
        #expect(canvas.model.document.annotations.count == 1)
        #expect(window.undoManager?.canUndo != true)
    }

    func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }

    func pathCanvas(clicking points: [(Double, Double)]) -> CanvasView {
        let canvas = CanvasView(
            model: EditorModel(
                original: Fixtures.sheet(width: 360, height: 400),
                document: EditDocument(scale: 1, salt: 7)))
        canvas.model.tool = .path
        let map = canvas.base.map
        for (x, y) in points {
            let p = Pointer(rendered: CGPoint(x: x, y: y), map: map)
            canvas.model.mouseDown(p, map: map)
            canvas.model.mouseUp(p, map: map, snap: false)
        }
        return canvas
    }

    @Test func committingInProgressFinishesAPath() {
        let canvas = pathCanvas(clicking: [(10, 10), (100, 10)])
        canvas.commitInProgress()
        #expect(canvas.model.building == nil && canvas.model.document.annotations.count == 1)
    }

    @Test func returnFinishesAPathAndEscapeStepsBack() {
        let canvas = pathCanvas(clicking: [(10, 10), (100, 10), (100, 100)])
        canvas.keyDown(with: key(53, "\u{1b}"))
        #expect(canvas.model.building != nil)
        canvas.keyDown(with: key(36, "\r"))
        #expect(canvas.model.building == nil)
        #expect(
            canvas.model.document.annotations.first?.shape
                == .path(
                    points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10)], closed: false,
                    fill: false))
    }
}
