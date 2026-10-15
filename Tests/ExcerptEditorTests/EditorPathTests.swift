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
        m.hover(Pointer(rendered: CGPoint(x: 80, y: 90), map: map(m)))
        #expect(m.displayDocument.annotations.last?.shape == path([(10, 10), (80, 90)]))
        #expect(shape(m) == path([(10, 10)]))
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
