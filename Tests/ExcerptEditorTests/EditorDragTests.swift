import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

@Suite struct EditorDragTests {
    func model(_ document: EditDocument = EditDocument(scale: 1, salt: 7)) -> EditorModel {
        EditorModel(original: Fixtures.sheet(width: 360, height: 400), document: document)
    }

    func map(_ m: EditorModel) -> RenderMap {
        Renderer.renderBase(m.original, edits: m.baseDocument).map
    }

    func pointer(_ m: EditorModel, _ x: Double, _ y: Double) -> Pointer {
        Pointer(rendered: CGPoint(x: x, y: y), map: map(m))
    }

    /// Drags in rendered pixels through the model's current map.
    func drag(
        _ m: EditorModel, _ from: CGPoint, _ to: CGPoint, snap: Bool = false
    ) {
        let map = map(m)
        m.mouseDown(Pointer(rendered: from, map: map), map: map)
        let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        m.mouseDragged(Pointer(rendered: middle, map: map), map: map, snap: snap)
        m.mouseUp(Pointer(rendered: to, map: map), map: map, snap: snap)
    }

    @Test func theArrowDragStartsAtTheHead() {
        let m = model()
        m.tool = .arrow
        m.setColor(.green)
        drag(m, CGPoint(x: 200, y: 100), CGPoint(x: 50, y: 300))
        #expect(
            m.document.annotations == [
                Annotation(
                    id: 1,
                    shape: .arrow(tail: CGPoint(x: 50, y: 300), head: CGPoint(x: 200, y: 100)),
                    color: .green)
            ])
        #expect(m.selection == .annotation(1))
        m.undo()
        #expect(m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func aDrawingToolGrabsItsOwnKindAndDrawsOverOthers() {
        let m = model()
        m.tool = .highlight
        drag(m, CGPoint(x: 20, y: 20), CGPoint(x: 300, y: 200))
        m.tool = .arrow
        drag(m, CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100))  // starts inside the highlight
        #expect(m.document.annotations.count == 2)
        m.selection = nil
        drag(m, CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 150))  // on the arrow: moves it
        #expect(m.document.annotations.count == 2)
        #expect(m.selection == .annotation(2))
        #expect(
            m.document.annotations[1].shape
                == .arrow(tail: CGPoint(x: 200, y: 150), head: CGPoint(x: 100, y: 150)))
    }

    @Test func rectanglesAndHighlightsAreDraggedOutFromAnyCorner() {
        let m = model()
        m.tool = .rectangle
        drag(m, CGPoint(x: 100, y: 90), CGPoint(x: 20, y: 30))
        m.tool = .highlight
        drag(m, CGPoint(x: 10, y: 200), CGPoint(x: 110, y: 220))
        #expect(
            m.document.annotations.map(\.shape) == [
                .rectangle(rect: CGRect(x: 20, y: 30, width: 80, height: 60)),
                .highlight(rect: CGRect(x: 10, y: 200, width: 100, height: 20)),
            ])
    }

    @Test func aClickWithoutADragAddsNothing() {
        let m = model()
        m.tool = .rectangle
        drag(m, CGPoint(x: 100, y: 90), CGPoint(x: 101, y: 91))
        #expect(m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func aCutIsPendingWhileDraggingAndAppliedOnRelease() {
        let m = model()
        m.tool = .cut
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 100, y: 47), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 104, y: 154), map: map), map: map, snap: true)
        #expect(m.pending == .cut(Cut(axis: .horizontal, lower: 40, upper: 160)))
        #expect(m.document.cuts.isEmpty)
        m.mouseUp(Pointer(rendered: CGPoint(x: 104, y: 154), map: map), map: map, snap: true)
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 40, upper: 160)])
        #expect(m.pending == nil)
    }

    @Test func aFullAxisTakesNoMoreCutsAndSaysSo() {
        let full = [Cut](
            repeating: Cut(axis: .horizontal, lower: 10, upper: 20),
            count: EditDocument.maximumCutsPerAxis)
        let m = model(EditDocument(scale: 1, cuts: full, salt: 7))
        m.tool = .cut
        #expect(
            m.cutLimitNote
                == "\(EditDocument.maximumCutsPerAxis.formatted()) row cuts, the most a capture holds"
        )
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 100, y: 47), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 104, y: 154), map: map), map: map, snap: true)
        #expect(m.pending == nil)
        m.mouseUp(Pointer(rendered: CGPoint(x: 104, y: 154), map: map), map: map, snap: true)
        #expect(m.document.cuts == full && !m.canUndo)
        drag(m, CGPoint(x: 60, y: 300), CGPoint(x: 200, y: 304))
        #expect(m.document.cuts.count == full.count + 1)
        #expect(m.document.cuts.last?.axis == .vertical)
    }

    @Test func optionKeepsTheDraggedEdges() {
        let m = model()
        m.tool = .cut
        drag(m, CGPoint(x: 100, y: 47), CGPoint(x: 104, y: 154), snap: false)
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 47, upper: 154)])
    }

    @Test func aCutDraggedAcrossASeamTakesInTheRemovedBand() {
        let m = model(
            EditDocument(scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)], salt: 7))
        m.tool = .cut
        // Rendered 60 is original 60; rendered 240 is past the 18px gap, original 322.
        drag(m, CGPoint(x: 30, y: 60), CGPoint(x: 30, y: 240))
        let bands = CutSet.normalized(m.document.cuts, axis: .horizontal, extent: 400)
        #expect(bands == [60..<322])
    }

    @Test func blurAndCropAreDraggedOut() {
        let m = model()
        m.tool = .blur
        drag(m, CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 50))
        #expect(
            m.document.annotations.map(\.shape) == [
                .blur(rect: CGRect(x: 10, y: 10, width: 60, height: 40))
            ])
        m.tool = .crop
        drag(m, CGPoint(x: 63, y: 18), CGPoint(x: 300, y: 239), snap: true)
        #expect(m.document.crop == PixelRect(x: 60, y: 20, width: 240, height: 220))
    }

    @Test func selectingAndMovingAnAnnotationIsOneStep() {
        let m = model()
        m.apply { $0.annotations = [note(1, CGRect(x: 20, y: 20, width: 60, height: 40))] }
        m.tool = .select
        drag(m, CGPoint(x: 50, y: 40), CGPoint(x: 80, y: 140))
        #expect(m.selection == .annotation(1))
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 50, y: 120, width: 60, height: 40)))
        m.undo()
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40)))
    }

    @Test func clickingASeamSelectsItAndItsHandleAdjustsTheCut() {
        let m = model(
            EditDocument(scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)], salt: 7))
        m.tool = .select
        // The gap is rendered 100..<118.
        drag(m, CGPoint(x: 30, y: 109), CGPoint(x: 30, y: 109))
        #expect(m.selection == .seam(.horizontal, 100..<200))
        // Clicking the selected seam's handle without moving changes nothing.
        drag(m, CGPoint(x: 30, y: 118), CGPoint(x: 30, y: 118))
        #expect(!m.canUndo && !m.isDirty)
        // Dragging the after handle up 40px reveals 40 more rows after the seam.
        drag(m, CGPoint(x: 30, y: 118), CGPoint(x: 30, y: 78))
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 100, upper: 160)])
        #expect(m.selection == .seam(.horizontal, 100..<160))
        // With snapping, the before handle dragged down 33px lands on the gridline at 140.
        drag(m, CGPoint(x: 30, y: 100), CGPoint(x: 30, y: 133), snap: true)
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 140, upper: 160)])
        m.undo()
        m.undo()
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 100, upper: 200)])
    }

    @Test func typingAddsEditsAndRemovesText() {
        let m = model()
        m.tool = .text
        let target = m.textTarget(at: pointer(m, 40, 60), map: map(m))
        #expect(target.id == nil)
        m.commitText(target, string: "Total")
        #expect(
            m.document.annotations.map(\.shape) == [
                .text(origin: CGPoint(x: 40, y: 60), string: "Total")
            ])
        let again = m.textTarget(at: pointer(m, 45, 70), map: map(m))
        #expect(again.id == 1 && again.string == "Total")
        m.commitText(again, string: "Grand total")
        #expect(
            m.document.annotations.map(\.shape) == [
                .text(origin: CGPoint(x: 40, y: 60), string: "Grand total")
            ])
        m.commitText(m.textTarget(at: pointer(m, 45, 70), map: map(m)), string: "  ")
        #expect(m.document.annotations.isEmpty)
        m.commitText(m.textTarget(at: pointer(m, 200, 200), map: map(m)), string: "")
        #expect(m.document.annotations.isEmpty)
    }

    @Test func previewThenCommitRecordsOneStepFromTheOriginal() {
        let m = model()
        let before = m.document
        var a = before
        a.annotations = [note(1, CGRect(x: 0, y: 0, width: 10, height: 10))]
        var b = before
        b.annotations = [note(1, CGRect(x: 5, y: 5, width: 10, height: 10))]
        m.preview(a)
        m.preview(b)
        #expect(!m.canUndo)
        m.commit(from: before)
        #expect(m.canUndo && m.isDirty)
        m.undo()
        #expect(m.document == before && !m.canUndo)
    }

    @Test func committingAnUnchangedDocumentRecordsNothing() {
        let m = model()
        let before = m.document
        m.preview(before)
        m.commit(from: before)
        #expect(!m.canUndo && !m.isDirty)
    }

    @Test func undoAndRedoWaitForADragToEnd() {
        let m = model()
        m.apply { $0.annotations = [note(1, CGRect(x: 20, y: 20, width: 60, height: 40))] }
        m.tool = .select
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 50, y: 40), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 80, y: 60), map: map), map: map, snap: false)
        let moved = m.document
        m.undo()
        #expect(m.document == moved && m.canUndo)
        m.redo()
        #expect(m.document == moved)
        m.mouseUp(Pointer(rendered: CGPoint(x: 80, y: 60), map: map), map: map, snap: false)
        m.undo()
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40)))
        #expect(m.canUndo)
    }

    @Test func changingToolMidDragRestoresThePreview() {
        let m = model()
        m.tool = .rectangle
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 10, y: 10), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 90, y: 90), map: map), map: map, snap: false)
        #expect(m.document.annotations.count == 1)
        m.tool = .select
        #expect(m.document.annotations.isEmpty && !m.isDirty && !m.canUndo && m.drag == nil)
    }

    @Test func undoKeepsTheSelectionWhileItStillExists() {
        let m = model()
        m.apply { $0.annotations = [note(1, CGRect(x: 20, y: 20, width: 60, height: 40))] }
        m.selection = .annotation(1)
        m.setColor(.blue)
        m.undo()
        #expect(m.selection == .annotation(1))
        m.redo()
        #expect(m.selection == .annotation(1))
        m.undo()
        m.undo()
        #expect(m.document.annotations.isEmpty && m.selection == nil)

        m.apply { $0.cuts = [Cut(axis: .horizontal, lower: 100, upper: 200)] }
        m.selection = .seam(.horizontal, 100..<200)
        m.apply { $0.annotations = [note(1, CGRect(x: 0, y: 0, width: 5, height: 5))] }
        m.undo()
        #expect(m.selection == .seam(.horizontal, 100..<200))
        m.undo()
        #expect(m.selection == nil)
    }

    @Test func aMovedSeamKeepsItsSelectionAcrossAMerge() {
        let m = model(
            EditDocument(
                scale: 1,
                cuts: [
                    Cut(axis: .horizontal, lower: 100, upper: 200),
                    Cut(axis: .horizontal, lower: 100, upper: 150),
                ], salt: 7))
        m.tool = .select
        m.selection = .seam(.horizontal, 100..<200)
        // The gap is rendered 100..<118; the after handle dragged up 40 reveals 40 rows.
        drag(m, CGPoint(x: 30, y: 118), CGPoint(x: 30, y: 78))
        #expect(m.selection == .seam(.horizontal, 100..<160))
    }

    @Test func deletingMidSeamDragCancelsTheDrag() {
        let cut = Cut(axis: .horizontal, lower: 100, upper: 200)
        let m = model(EditDocument(scale: 1, cuts: [cut], salt: 7))
        m.tool = .select
        m.selection = .seam(.horizontal, 100..<200)
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 30, y: 118), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 30, y: 98), map: map), map: map, snap: false)
        m.deleteSelection()
        m.mouseUp(Pointer(rendered: CGPoint(x: 30, y: 78), map: map), map: map, snap: false)
        #expect(m.document.cuts.isEmpty && m.drag == nil && m.pending == nil)
        m.undo()
        #expect(m.document.cuts == [cut] && !m.canUndo)
    }

    @Test func deletingMidMoveDragLeavesNoPhantomStep() {
        let m = model()
        m.apply { $0.annotations = [note(1, CGRect(x: 20, y: 20, width: 60, height: 40))] }
        m.tool = .select
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 50, y: 40), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 80, y: 60), map: map), map: map, snap: false)
        m.deleteSelection()
        m.mouseUp(Pointer(rendered: CGPoint(x: 90, y: 70), map: map), map: map, snap: false)
        #expect(m.document.annotations.isEmpty)
        m.undo()
        #expect(m.document.annotations.count == 1)
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40)))
        m.undo()  // only the setup step remains below the delete
        #expect(m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func toolsWorkOnAnAlreadyCroppedDocument() {
        let m = model(
            EditDocument(scale: 1, crop: PixelRect(x: 60, y: 40, width: 240, height: 300), salt: 7))
        m.tool = .cut
        // Rendered (30, 47..154) is original (90, 87..194).
        drag(m, CGPoint(x: 30, y: 47), CGPoint(x: 30, y: 154))
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 87, upper: 194)])
        m.tool = .select
        m.apply { $0.annotations = [note(1, CGRect(x: 100, y: 50, width: 40, height: 20))] }
        // Rendered (60, 20) is original (120, 60), inside the rectangle.
        drag(m, CGPoint(x: 60, y: 20), CGPoint(x: 70, y: 25))
        #expect(m.selection == .annotation(1))
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 110, y: 55, width: 40, height: 20)))
    }

    @Test func adjustingASeamUnderACropKeepsTheOffCropPartOfItsCut() {
        // The cut 20..<120 straddles the crop's top edge (40); the seam shows 40..<120.
        let m = model(
            EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 20, upper: 120)],
                crop: PixelRect(x: 60, y: 40, width: 240, height: 300), salt: 7))
        m.tool = .select
        let seam = map(m).seams(.horizontal)[0]
        #expect(seam.band == 40..<120)
        m.selection = .seam(.horizontal, seam.band)
        // Drag the in-crop handle (the band's after edge) up 10 rendered pixels.
        let y = Double(seam.gap.upperBound)
        drag(m, CGPoint(x: 30, y: y), CGPoint(x: 30, y: y - 10))
        #expect(m.document.cuts == [Cut(axis: .horizontal, lower: 20, upper: 110)])
        #expect(m.selection == .seam(.horizontal, 40..<110))
    }

    @Test func draggingACropClippedEdgeWithinItsOverhangChangesNothing() {
        let m = model(
            EditDocument(
                scale: 1, cuts: [Cut(axis: .horizontal, lower: 20, upper: 120)],
                crop: PixelRect(x: 60, y: 40, width: 240, height: 300), salt: 7))
        m.tool = .select
        let seam = map(m).seams(.horizontal)[0]
        m.selection = .seam(.horizontal, seam.band)
        // The before edge is clipped at the crop (40); 20 rows of the cut lie above it.
        let y = Double(seam.gap.lowerBound)
        drag(m, CGPoint(x: 30, y: y), CGPoint(x: 30, y: y - 10))
        #expect(!m.canUndo && !m.isDirty)
    }

    @Test func movingAnAnnotationAcrossASeamMovesItByOriginalPixels() {
        let m = model(
            EditDocument(scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)], salt: 7))
        m.apply { $0.annotations = [note(1, CGRect(x: 20, y: 20, width: 60, height: 40))] }
        m.tool = .select
        let map = map(m)
        let delta = map.original(CGPoint(x: 50, y: 160)).y - map.original(CGPoint(x: 50, y: 40)).y
        #expect(delta > 120)  // the seam's 100 removed rows are crossed, not just 120 rendered ones
        drag(m, CGPoint(x: 50, y: 40), CGPoint(x: 50, y: 160))
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 20, y: 20 + Double(delta), width: 60, height: 40)))
        m.undo()
        #expect(
            m.document.annotations[0].shape
                == .rectangle(rect: CGRect(x: 20, y: 20, width: 60, height: 40)))
    }

    @Test func aCropDragWhileCroppedStartsFromTheWholeCapture() {
        let m = model(
            EditDocument(scale: 1, crop: PixelRect(x: 60, y: 40, width: 120, height: 100), salt: 7))
        m.tool = .crop
        // Under the crop tool the canvas shows the whole capture, so rendered == original.
        let whole = Renderer.renderBase(m.original, edits: m.displayDocument).map
        m.mouseDown(Pointer(rendered: CGPoint(x: 0, y: 0), map: whole), map: whole)
        m.mouseDragged(
            Pointer(rendered: CGPoint(x: 180, y: 200), map: whole), map: whole, snap: false)
        m.mouseUp(Pointer(rendered: CGPoint(x: 180, y: 200), map: whole), map: whole, snap: false)
        #expect(m.document.crop == PixelRect(x: 0, y: 0, width: 180, height: 200))
        m.undo()
        #expect(m.document.crop == PixelRect(x: 60, y: 40, width: 120, height: 100))
    }
}
