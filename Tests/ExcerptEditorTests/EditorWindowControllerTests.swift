import AppKit
import ExcerptTestSupport
import Testing

@testable import ExcerptCore
@testable import ExcerptEditor

@MainActor
@Suite struct EditorWindowControllerTests {
    /// The scroll view's width can change with no window resize, as when the scroller style
    /// settles after the window shows; the canvas refits then, not at the next edit.
    @Test func theCanvasRefitsWhenTheScrollViewNarrows() throws {
        let capture = LoadedCapture(
            primary: URL(fileURLWithPath: "/tmp/probe.png"),
            original: Fixtures.sheet(width: 2400, height: 400), edits: EditDocument(scale: 1),
            supersedesMaster: false)
        let editor = EditorWindowController(
            capture: capture, save: { _ in Data() }, copy: { _ in true }, forClaude: { _, _ in },
            borderStyle: .initial, rememberBorder: { _ in }, annotationStyle: .initial,
            rememberStyle: { _ in }, onClose: {})
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
