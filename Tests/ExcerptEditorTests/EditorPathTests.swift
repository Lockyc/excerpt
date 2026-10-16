import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

@Suite struct EditorPathTests {
    func model() -> EditorModel {
        let m = EditorModel(
            original: Fixtures.sheet(width: 360, height: 400),
            document: EditDocument(scale: 1, salt: 7))
        m.tool = .path
        return m
    }

    func map(_ m: EditorModel) -> RenderMap {
        Renderer.renderBase(m.original, edits: m.baseDocument).map
    }

    func click(_ m: EditorModel, _ x: Double, _ y: Double, count: Int = 1, option: Bool = false) {
        let map = map(m)
        let p = Pointer(rendered: CGPoint(x: x, y: y), map: map)
        m.mouseDown(p, map: map, clickCount: count, option: option)
        m.mouseUp(p, map: map, snap: false)
    }

    func stroke(_ m: EditorModel, _ points: [CGPoint]) {
        let map = map(m)
        m.mouseDown(Pointer(rendered: points[0], map: map), map: map)
        for p in points.dropFirst().dropLast() {
            m.mouseDragged(Pointer(rendered: p, map: map), map: map, snap: false)
        }
        m.mouseUp(Pointer(rendered: points.last!, map: map), map: map, snap: false)
    }

    func shape(_ m: EditorModel) -> Shape? { m.document.annotations.last?.shape }

    func path(_ points: [(Double, Double)], closed: Bool = false) -> Shape {
        .path(points: points.map { CGPoint(x: $0.0, y: $0.1) }, closed: closed, fill: false)
    }

    @Test func clicksBuildAPathThatFinishesAsOneStep() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        click(m, 100, 100)
        #expect(m.building != nil && m.canUndo)
        m.finishPath()
        #expect(m.building == nil)
        #expect(shape(m) == path([(10, 10), (100, 10), (100, 100)]))
        #expect(m.selection == .annotation(1))
        m.undo()
        #expect(m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func aDoubleClickFinishesWithoutADuplicateVertex() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        click(m, 100, 10, count: 2)
        #expect(m.building == nil)
        #expect(shape(m) == path([(10, 10), (100, 10)]))
    }

    @Test func clickingTheFirstVertexOfThreeCloses() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        click(m, 100, 100)
        click(m, 12, 11)
        #expect(m.building == nil)
        #expect(shape(m) == path([(10, 10), (100, 10), (100, 100)], closed: true))
    }

    @Test func clickingTheFirstVertexOfTwoAddsAVertex() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        click(m, 12, 11)
        #expect(m.building != nil)
        m.finishPath()
        #expect(shape(m) == path([(10, 10), (100, 10), (12, 11)]))
    }

    @Test func aLoneClickLeavesNothing() {
        let m = model()
        click(m, 10, 10)
        m.finishPath()
        #expect(m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func aFreehandStrokeFinishesOnReleaseSimplified() {
        let m = model()
        stroke(m, (0...40).map { CGPoint(x: 20 + Double($0) * 5, y: $0 % 2 == 0 ? 50 : 51) })
        #expect(m.building == nil)
        #expect(shape(m) == path([(20, 50), (220, 50)]))
        #expect(m.selection == .annotation(1))
        #expect(m.canUndo)
    }

    @Test func aFreehandRunInsideAClickedPathDoesNotFinishIt() {
        let m = model()
        click(m, 10, 10)
        stroke(m, [CGPoint(x: 100, y: 10), CGPoint(x: 150, y: 10), CGPoint(x: 200, y: 10)])
        #expect(m.building != nil)
        click(m, 200, 200)
        m.finishPath()
        #expect(shape(m) == path([(10, 10), (100, 10), (200, 10), (200, 200)]))
    }

    @Test func escapeDropsTheLastVertexThenAbandons() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        m.dropLastVertex()
        #expect(m.building != nil)
        #expect(shape(m) == path([(10, 10)]))
        m.dropLastVertex()
        #expect(m.building == nil && m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func switchingToolsFinishesThePath() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        m.tool = .select
        #expect(m.building == nil && m.document.annotations.count == 1 && m.canUndo)
    }

    @Test func undoWhileBuildingRemovesTheWholePath() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        #expect(m.canUndo)
        m.undo()
        #expect(m.building == nil && m.document.annotations.isEmpty)
    }

    @Test func theRubberBandShowsButIsNotStored() {
        let m = model()
        click(m, 10, 10)
        m.hover(Pointer(rendered: CGPoint(x: 80, y: 90), map: map(m)), map: map(m))
        #expect(m.displayDocument.annotations.last?.shape == path([(10, 10), (80, 90)]))
        #expect(shape(m) == path([(10, 10)]))
    }

    @Test func onTheFirstVertexThePathShowsTheCloseAPressWouldMake() {
        let m = model()
        click(m, 10, 10)
        click(m, 200, 10)
        click(m, 200, 200)
        let near = Pointer(rendered: CGPoint(x: 13, y: 12), map: map(m))
        #expect(m.grab(at: near, map: map(m), option: false) == .closePath)
        m.hover(near, map: map(m))
        #expect(
            m.displayDocument.annotations.last?.shape
                == path([(10, 10), (200, 10), (200, 200)], closed: true))
        m.hover(Pointer(rendered: CGPoint(x: 60, y: 90), map: map(m)), map: map(m))
        #expect(
            m.displayDocument.annotations.last?.shape
                == path([(10, 10), (200, 10), (200, 200), (60, 90)]))
    }

    @Test func grabNamesWhatAPressWouldMove() {
        let m = model()
        triangle(m)
        let map = map(m)
        func grab(_ x: Double, _ y: Double) -> Grab? {
            m.grab(at: Pointer(rendered: CGPoint(x: x, y: y), map: map), map: map, option: false)
        }
        #expect(grab(200, 200) == .vertex(id: 1, index: 2))
        #expect(grab(105, 10) == .annotation(1))
        #expect(grab(300, 350) == nil)
        m.tool = .arrow  // another tool's kind is drawn over, not grabbed
        #expect(grab(105, 10) == nil)
        m.tool = .select
        #expect(grab(105, 10) == .annotation(1))
    }

    func triangle(_ m: EditorModel) {
        click(m, 10, 10)
        click(m, 200, 10)
        click(m, 200, 200)
        click(m, 10, 10)  // closes and selects
    }

    @Test func draggingAVertexReshapesAsOneStep() {
        let m = model()
        triangle(m)
        stroke(m, [CGPoint(x: 200, y: 200), CGPoint(x: 150, y: 250), CGPoint(x: 100, y: 300)])
        #expect(shape(m) == path([(10, 10), (200, 10), (100, 300)], closed: true))
        m.undo()
        #expect(shape(m) == path([(10, 10), (200, 10), (200, 200)], closed: true))
    }

    @Test func optionClickingAVertexDeletesItAndATriangleOpens() {
        let m = model()
        triangle(m)
        click(m, 200, 200, option: true)
        #expect(shape(m) == path([(10, 10), (200, 10)]))
        click(m, 200, 10, option: true)  // two left: the path keeps them
        #expect(shape(m) == path([(10, 10), (200, 10)]))
    }

    @Test func optionClickingASegmentInsertsAVertexToDrag() {
        let m = model()
        triangle(m)
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 100, y: 10), map: map), map: map, option: true)
        m.mouseUp(Pointer(rendered: CGPoint(x: 100, y: 40), map: map), map: map, snap: false)
        #expect(shape(m) == path([(10, 10), (100, 40), (200, 10), (200, 200)], closed: true))
        m.undo()
        #expect(shape(m) == path([(10, 10), (200, 10), (200, 200)], closed: true))
    }

    @Test func theSelectToolReshapesAtAVertexAndMovesElsewhere() {
        let m = model()
        triangle(m)
        m.tool = .select
        m.selection = .annotation(1)
        stroke(m, [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 30)])
        #expect(shape(m) == path([(30, 30), (200, 10), (200, 200)], closed: true))
        stroke(m, [CGPoint(x: 200, y: 100), CGPoint(x: 210, y: 100), CGPoint(x: 220, y: 100)])
        #expect(shape(m) == path([(50, 30), (220, 10), (220, 200)], closed: true))
    }

    @Test func undoWithOneVertexKeepsTheEditBefore() {
        let m = model()
        m.tool = .rectangle
        stroke(m, [CGPoint(x: 20, y: 300), CGPoint(x: 60, y: 330), CGPoint(x: 100, y: 360)])
        m.tool = .path
        click(m, 10, 10)
        m.undo()
        #expect(m.building == nil)
        #expect(
            m.document.annotations.map(\.shape) == [
                .rectangle(rect: CGRect(x: 20, y: 300, width: 80, height: 60))
            ])
    }

    @Test func aClickBesideAVertexLeavesItWhereItIs() {
        let m = model()
        triangle(m)
        click(m, 206, 200)
        #expect(shape(m) == path([(10, 10), (200, 10), (200, 200)], closed: true))
        m.undo()
        #expect(m.document.annotations.isEmpty)  // only the drawing was recorded
    }

    @Test func aVertexDragKeepsItsGrabOffset() {
        let m = model()
        triangle(m)
        stroke(m, [CGPoint(x: 206, y: 200), CGPoint(x: 226, y: 220), CGPoint(x: 246, y: 240)])
        #expect(shape(m) == path([(10, 10), (200, 10), (240, 240)], closed: true))
    }

    @Test func aJitteryFirstClickStartsAPolyline() {
        let m = model()
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 50, y: 50), map: map), map: map)
        for x in [51.0, 49, 51, 49, 51] {
            m.mouseDragged(Pointer(rendered: CGPoint(x: x, y: 50), map: map), map: map, snap: false)
        }
        m.mouseUp(Pointer(rendered: CGPoint(x: 50, y: 50), map: map), map: map, snap: false)
        #expect(m.building != nil)
        #expect(shape(m) == path([(50, 50)]))
    }

    @Test func aTwoPointPathDoesNotClose() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        click(m, 100, 10, count: 2)
        m.setClosed(true)
        #expect(shape(m) == path([(10, 10), (100, 10)]))
    }

    @Test func redoWaitsWhileBuilding() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        click(m, 100, 10, count: 2)
        m.undo()
        #expect(m.canRedo)
        click(m, 50, 50)
        #expect(!m.canRedo)
    }

    @Test func pressingTheCurrentToolKeepsBuilding() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        m.tool = .path
        #expect(m.building != nil)
    }

    @Test func aCancelledFreehandRunIsSimplified() {
        let m = model()
        click(m, 10, 10)
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 100, y: 10), map: map), map: map)
        for x in stride(from: 105.0, through: 200, by: 5) {
            m.mouseDragged(Pointer(rendered: CGPoint(x: x, y: 10), map: map), map: map, snap: false)
        }
        m.cancelDrag()
        #expect(shape(m) == path([(10, 10), (100, 10), (200, 10)]))
    }

    @Test func thePathBeingBuiltTakesTheBarAndItsStyle() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        #expect(m.itemOptions?.first == .color(.red))
        m.setColor(.blue)
        m.setWidth(.thick)
        #expect(m.building != nil)
        click(m, 100, 100, count: 2)
        #expect(m.document.annotations.last?.color == .blue)
        #expect(m.document.annotations.last?.width == .thick)
        m.undo()
        #expect(m.document.annotations.isEmpty)  // one step: drawing and restyle together
    }

    @Test func deletingWhileBuildingAbandonsThePath() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        m.deleteSelection()
        #expect(m.building == nil && m.document.annotations.isEmpty && !m.canUndo)
    }

    @Test func pressingAnExistingPathMovesItInsteadOfStartingOne() {
        let m = model()
        click(m, 10, 10)
        click(m, 100, 10)
        m.finishPath()
        m.selection = nil
        stroke(m, [CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 30), CGPoint(x: 50, y: 50)])
        #expect(m.document.annotations.count == 1)
        #expect(shape(m) == path([(10, 50), (100, 50)]))
    }
}
