import AppKit
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

/// The text controls on the item bar, driven through their own actions.
@MainActor
@Suite struct ItemBarTests {
    /// A canvas typing new (legacy) text, its bar showing.
    func typing() -> CanvasView {
        let model = EditorModel(
            original: Fixtures.sheet(width: 360, height: 400),
            document: EditDocument(scale: 1, salt: 7))
        let canvas = CanvasView(model: model)
        canvas.zoom = 1
        model.tool = .text
        let map = canvas.map
        model.beginTyping(at: Pointer(rendered: CGPoint(x: 40, y: 60), map: map), map: map)
        model.updateTyping("Total")
        return canvas
    }

    func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        [view].compactMap { $0 as? T } + view.subviews.flatMap { views(type, in: $0) }
    }

    func style(_ canvas: CanvasView) -> TextStyle? {
        guard case .text(_, _, _, let style)? = canvas.model.typing?.shape else { return nil }
        return style
    }

    func fire(_ control: NSControl) { control.sendAction(control.action, to: control.target) }

    @Test func theSizeStepperStepsAgainAfterItsFirstStep() throws {
        let canvas = typing()
        let stepper = try #require(views(NSStepper.self, in: canvas.itemBarView).first)
        let start = StrokeWidth.initial.textPoints
        #expect(stepper.doubleValue == start)
        // What autorepeat does: the same control, stepped and fired again.
        for _ in 0..<2 {
            stepper.doubleValue += stepper.increment
            fire(stepper)
        }
        #expect(style(canvas)?.points == start + 2 * EditorModel.textSizeStep)
        #expect(stepper.isDescendant(of: canvas.itemBarView))
        let label = try #require(stepper.superview?.subviews.first as? NSTextField)
        #expect(label.stringValue == TextStyle.label(points: start + 1))
    }

    @Test func boldFontAndAlignmentDriveTheText() throws {
        let canvas = typing()
        let bar = canvas.itemBarView
        let bold = try #require(
            views(NSButton.self, in: bar).first {
                $0.image?.accessibilityDescription == "Bold"
            })
        #expect(bold.state == .on)
        bold.performClick(nil)
        #expect(style(canvas)?.bold == false)

        let menu = try #require(views(NSPopUpButton.self, in: bar).first)
        menu.selectItem(at: try #require(TextFont.allCases.firstIndex(of: .serif)))
        fire(menu)
        #expect(style(canvas)?.font == .serif)

        let alignment = try #require(
            views(NSSegmentedControl.self, in: bar).first {
                $0.segmentCount == TextAlign.shown.count
            })
        alignment.selectedSegment = try #require(TextAlign.shown.firstIndex(of: .centered))
        fire(alignment)
        #expect(style(canvas)?.alignment == .centered)
        // Each change kept the controls and shows the new values.
        #expect(bold.isDescendant(of: bar) && bold.state == .off)
        #expect(menu.isDescendant(of: bar) && menu.titleOfSelectedItem == TextFont.serif.label)
        #expect(alignment.isDescendant(of: bar))
    }
}
