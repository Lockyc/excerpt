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

    /// The colour swatches: the palette's six, then the sampled one.
    func swatches(_ bar: NSView) throws -> NSSegmentedControl {
        try #require(
            views(NSSegmentedControl.self, in: bar).first {
                $0.segmentCount == Palette.allCases.count + 1
            })
    }

    /// An item in a sampled colour — an auto-coloured patch, matched text — shows its own
    /// colour lit on the sampled swatch, whatever was last picked; other items show the last
    /// pick, unlit.
    @Test func theSampledSwatchShowsTheSelectedItemsSampledColour() throws {
        let slate = RGBA(r: 0x27, g: 0x2C, b: 0x35, a: 255)
        let picked = RGBA(r: 0, g: 90, b: 200, a: 255)
        let patch = Annotation(
            id: 1,
            shape: .patch(rect: CGRect(x: 10, y: 10, width: 50, height: 20), autoColor: true),
            color: .sampled(slate))
        let arrow = Annotation(
            id: 2, shape: .arrow(tail: CGPoint(x: 100, y: 100), head: CGPoint(x: 200, y: 150)))
        let model = EditorModel(
            original: Fixtures.sheet(width: 360, height: 400),
            document: EditDocument(scale: 1, annotations: [patch, arrow], salt: 7),
            style: AnnotationStyle(lastSampled: picked))
        let sample = Palette.allCases.count
        let bar = ItemBar()

        model.selection = .annotation(patch.id)
        bar.show(try #require(model.itemOptions))
        let lit = try swatches(bar)
        #expect(lit.isEnabled(forSegment: sample))
        #expect(lit.selectedSegment == sample)
        #expect(model.itemOptions?.first == .color(.sampled(slate), sample: slate))

        model.selection = .annotation(arrow.id)
        bar.show(try #require(model.itemOptions))
        #expect(try swatches(bar).selectedSegment == Palette.allCases.firstIndex(of: .initial))
        #expect(model.itemOptions?.first == .color(.initial, sample: picked))
    }
}
