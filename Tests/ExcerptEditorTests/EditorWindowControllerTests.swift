import AppKit
import ExcerptTestSupport
import Testing

@testable import ExcerptCore
@testable import ExcerptEditor

@MainActor
@Suite struct EditorWindowControllerTests {
    func editor(width: Int = 2400) -> EditorWindowController {
        let capture = LoadedCapture(
            primary: URL(fileURLWithPath: "/tmp/probe.png"),
            original: Fixtures.sheet(width: width, height: 400), edits: EditDocument(scale: 1),
            supersedesMaster: false)
        return EditorWindowController(
            captures: [capture], save: { _, _ in Data() }, copy: { _ in true },
            forClaude: { _, _, _ in },
            borderStyle: .initial, rememberBorder: { _ in }, annotationStyle: .initial,
            rememberStyle: { _ in }, onClose: {})
    }

    func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return [view].compactMap { $0 as? T } + view.subviews.flatMap { views(type, in: $0) }
    }

    func canvas(of editor: EditorWindowController) throws -> CanvasView {
        let found = views(CanvasView.self, in: editor.window?.contentView).first
        return try #require(found)
    }

    /// Clicks `tool`'s toolbar segment.
    func choose(_ tool: Tool, in editor: EditorWindowController) throws {
        let tools = try #require(
            views(NSSegmentedControl.self, in: editor.window?.contentView).first {
                $0.segmentCount == Tool.allCases.count
            })
        tools.selectedSegment = try #require(Tool.allCases.firstIndex(of: tool))
        tools.sendAction(tools.action, to: tools.target)
    }

    @Test func aToolCanBeChosenWhileAPathIsBuilt() throws {
        let editor = editor()
        defer { editor.window?.orderOut(nil) }
        let canvas = try canvas(of: editor)
        try choose(.path, in: editor)
        let map = canvas.base.map
        for x in [10.0, 100] {
            let p = Pointer(rendered: CGPoint(x: x, y: 10), map: map)
            canvas.model.mouseDown(p, map: map)
            canvas.model.mouseUp(p, map: map, snap: false)
        }
        try choose(.rectangle, in: editor)
        #expect(canvas.model.tool == .rectangle)
        #expect(canvas.model.building == nil)
    }

    @Test func aToolCanBeChosenWhileTyping() throws {
        let editor = editor()
        defer { editor.window?.orderOut(nil) }
        let canvas = try canvas(of: editor)
        try choose(.text, in: editor)
        canvas.beginText(at: Pointer(rendered: CGPoint(x: 40, y: 60), map: canvas.base.map))
        try choose(.arrow, in: editor)
        #expect(canvas.model.tool == .arrow)
    }

    /// The scroll view's width can change with no window resize, as when the scroller style
    /// settles after the window shows; the canvas refits then, not at the next edit.
    @Test func theCanvasRefitsWhenTheScrollViewNarrows() throws {
        let editor = editor()
        defer { editor.window?.orderOut(nil) }
        let scrollView = try #require(
            editor.window?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let canvas = try #require(scrollView.documentView)

        scrollView.scrollerStyle = .overlay
        #expect(canvas.frame.width == scrollView.contentSize.width)
        scrollView.scrollerStyle = .legacy
        #expect(scrollView.contentSize.width < scrollView.frame.width)
        #expect(canvas.frame.width == scrollView.contentSize.width)
    }
}
