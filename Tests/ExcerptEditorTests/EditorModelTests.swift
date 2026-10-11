import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

@Suite struct ToolTests {
    @Test func everyToolHasItsKey() {
        #expect(Tool.allCases.map(\.key) == ["v", "a", "r", "t", "h", "b", "k", "c"])
        #expect(Tool(key: "K") == .crop)
        #expect(Tool(key: "x") == nil)
    }
}

@Suite struct UndoStackTests {
    @Test func undoAndRedoWalkTheValues() {
        var stack = UndoStack<Int>()
        stack.record(1)
        stack.record(2)
        #expect(stack.undo(from: 3) == 2)
        #expect(stack.undo(from: 2) == 1)
        #expect(stack.undo(from: 1) == nil)
        #expect(stack.redo(from: 1) == 2)
        stack.record(2)
        #expect(!stack.canRedo)
    }
}

@Suite struct EditorModelTests {
    func model() -> EditorModel {
        EditorModel(
            original: Fixtures.sheet(width: 360, height: 400),
            document: EditDocument(scale: 2, salt: 7))
    }

    @Test func applyIsOneUndoableStep() {
        let m = model()
        m.apply { $0.cuts.append(Cut(axis: .horizontal, lower: 40, upper: 120)) }
        #expect(m.isDirty && m.canUndo)
        m.undo()
        #expect(m.document.cuts.isEmpty && !m.isDirty)
        m.redo()
        #expect(m.document.cuts.count == 1)
    }

    @Test func borderIsOneUndoableStep() {
        let m = model()
        m.setBorder(true)
        #expect(m.document.border && m.isDirty)
        m.undo()
        #expect(!m.document.border && !m.isDirty)
    }

    @Test func aNoOpRecordsNothing() {
        let m = model()
        m.apply { _ in }
        #expect(!m.canUndo)
    }

    @Test func undoAndRedoPreserveTheSalt() {
        let m = model()
        let salt = m.document.salt
        m.apply { $0.cuts.append(Cut(axis: .horizontal, lower: 40, upper: 120)) }
        #expect(m.document.salt == salt)
        m.undo()
        #expect(m.document.salt == salt)
        m.redo()
        #expect(m.document.salt == salt)
    }

    @Test func undoAcrossASaveTracksDirtiness() {
        let m = model()
        m.apply { $0.cuts.append(Cut(axis: .horizontal, lower: 40, upper: 120)) }
        m.markSaved()
        #expect(!m.isDirty)
        m.apply { $0.annotations.append(note(1, CGRect(x: 0, y: 0, width: 10, height: 10))) }
        #expect(m.isDirty)
        m.undo()
        #expect(!m.isDirty)  // back to exactly what was saved
        m.undo()
        #expect(m.isDirty && m.document.cuts.isEmpty)  // before the save: unsaved again
        m.redo()
        #expect(!m.isDirty)
    }

    @Test func colourAndWidthRestyleTheSelection() {
        let m = model()
        m.apply { $0.annotations.append(note(1, CGRect(x: 0, y: 0, width: 10, height: 10))) }
        m.selection = .annotation(1)
        #expect(m.selectionTakesStyle)
        m.setColor(.blue)
        m.setWidth(.thick)
        #expect(m.document.annotations[0].color == .blue)
        #expect(m.document.annotations[0].width == .thick)
        m.undo()
        #expect(m.document.annotations[0].width == .medium)
    }

    @Test func aSelectedBlurIsNotRestyled() {
        let m = model()
        m.apply {
            $0.annotations.append(
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 0, y: 0, width: 40, height: 40))))
        }
        m.selection = .annotation(1)
        #expect(!m.selectionTakesStyle)
        let before = m.document
        m.setColor(.blue)
        m.setWidth(.thick)
        #expect(m.document == before)
        m.undo()
        #expect(m.document.annotations.isEmpty)  // the only step is the blur's own
        #expect(!m.canUndo)
        #expect(m.color == .blue && m.width == .thick)  // new annotations still get the style
    }

    @Test func aSeamSelectionIsNotABlurSelection() {
        let m = model()
        m.apply { $0.cuts = [Cut(axis: .horizontal, lower: 100, upper: 200)] }
        m.selection = .seam(.horizontal, 100..<200)
        #expect(!m.selectedAnnotationIsBlur && !m.selectionTakesStyle)
        m.setColor(.blue)
        #expect(m.color == .blue)
    }

    @Test func newAnnotationsStartWithTheInitialStyle() {
        let m = model()
        #expect(m.color == Palette.initial && m.width == StrokeWidth.initial)
    }

    @Test func canDeleteFollowsTheSelectionAndTheCrop() {
        let m = model()
        #expect(!m.canDelete)
        m.apply { $0.crop = PixelRect(x: 0, y: 0, width: 100, height: 100) }
        #expect(!m.canDelete)
        m.tool = .crop
        #expect(m.canDelete)
        m.deleteSelection()
        #expect(!m.canDelete)
        m.tool = .select
        m.apply { $0.annotations.append(note(1, CGRect(x: 0, y: 0, width: 10, height: 10))) }
        m.selection = .annotation(1)
        #expect(m.canDelete)
    }

    @Test func deleteRemovesTheSelectionOrTheCrop() {
        let m = model()
        m.apply {
            $0.annotations.append(note(1, CGRect(x: 0, y: 0, width: 10, height: 10)))
            $0.cuts = [
                Cut(axis: .horizontal, lower: 40, upper: 100),
                Cut(axis: .horizontal, lower: 90, upper: 120),
            ]
            $0.crop = PixelRect(x: 0, y: 0, width: 100, height: 100)
        }
        m.selection = .annotation(1)
        m.deleteSelection()
        #expect(m.document.annotations.isEmpty && m.selection == nil)
        m.selection = .seam(.horizontal, 40..<120)
        m.deleteSelection()
        #expect(m.document.cuts.isEmpty)
        m.tool = .crop
        m.deleteSelection()
        #expect(m.document.crop == nil)
    }

    @Test func theCropToolShowsTheWholeCapture() {
        let m = model()
        m.apply { $0.crop = PixelRect(x: 10, y: 10, width: 100, height: 100) }
        #expect(m.displayDocument.crop != nil)
        m.tool = .crop
        #expect(m.displayDocument.crop == nil)
        #expect(m.document.crop != nil)
    }

    @Test func movingAnArrowKeepsTheBaseButMovingABlurDoesOnlyOnRelease() {
        let m = model()
        let arrow = Annotation(
            id: 1, shape: .arrow(tail: CGPoint(x: 0, y: 0), head: CGPoint(x: 50, y: 50)))
        let blur = Annotation(id: 2, shape: .blur(rect: CGRect(x: 0, y: 0, width: 40, height: 40)))
        m.apply { $0.annotations = [arrow, blur] }
        let base = m.baseDocument
        m.apply { $0.annotations[0].shape = arrow.shape.offset(dx: 5, dy: 5) }
        #expect(m.baseDocument == base)

        // Mid-drag the base still shows the blur where it started, and the moving rect is an
        // outline; the release re-renders once.
        let map = Renderer.renderBase(m.original, edits: m.baseDocument).map
        func at(_ x: Double, _ y: Double) -> Pointer {
            Pointer(rendered: CGPoint(x: x, y: y), map: map)
        }
        let before = m.baseDocument
        m.tool = .select
        m.mouseDown(at(30, 30), map: map)
        m.mouseDragged(at(40, 45), map: map, snap: false)
        #expect(m.baseDocument == before)
        #expect(m.pending == .region(CGRect(x: 10, y: 15, width: 40, height: 40)))
        m.mouseUp(at(40, 45), map: map, snap: false)
        #expect(m.baseDocument != before)
        #expect(m.pending == nil)
        #expect(
            m.document.annotations[1].shape
                == .blur(rect: CGRect(x: 10, y: 15, width: 40, height: 40)))
    }

    @Test func reportsAnnotationsHiddenByCuts() {
        let m = model()
        m.apply {
            $0.cuts = [Cut(axis: .horizontal, lower: 100, upper: 300)]
            $0.annotations = [
                note(1, CGRect(x: 10, y: 150, width: 50, height: 20)),
                note(2, CGRect(x: 10, y: 200, width: 50, height: 20)),
                note(3, CGRect(x: 10, y: 20, width: 50, height: 20)),
            ]
        }
        let map = Renderer.renderBase(m.original, edits: m.baseDocument).map
        #expect(m.hiddenNote(map: map) == "2 annotations hidden by cuts")
        m.apply { $0.annotations.removeFirst() }
        #expect(m.hiddenNote(map: map) == "1 annotation hidden by a cut")
        m.apply { $0.annotations.removeFirst() }
        #expect(m.hiddenNote(map: map) == "")
    }
}
