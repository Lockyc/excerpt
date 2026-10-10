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
        let target = m.textTarget(at: CGPoint(x: 40, y: 60), map: map(m))
        #expect(target.id == nil)
        m.commitText(target, string: "Total")
        #expect(
            m.document.annotations.map(\.shape) == [
                .text(origin: CGPoint(x: 40, y: 60), string: "Total")
            ])
        let again = m.textTarget(at: CGPoint(x: 45, y: 70), map: map(m))
        #expect(again.id == 1 && again.string == "Total")
        m.commitText(again, string: "Grand total")
        #expect(
            m.document.annotations.map(\.shape) == [
                .text(origin: CGPoint(x: 40, y: 60), string: "Grand total")
            ])
        m.commitText(m.textTarget(at: CGPoint(x: 45, y: 70), map: map(m)), string: "  ")
        #expect(m.document.annotations.isEmpty)
        m.commitText(m.textTarget(at: CGPoint(x: 200, y: 200), map: map(m)), string: "")
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
}
