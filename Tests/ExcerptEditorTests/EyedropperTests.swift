import AppKit
import CoreGraphics
import ExcerptCore
import Foundation
import Testing

@testable import ExcerptEditor

@Suite struct EyedropperTests {
    static let blue = RGBA(r: 10, g: 20, b: 200, a: 255)
    static let ground = RGBA(r: 240, g: 240, b: 240, a: 255)

    /// A 100x100 light capture with one blue pixel at (50, 50).
    func model() -> EditorModel {
        var buffer = PixelBuffer(
            width: 100, height: 100,
            bytes: Array(
                repeating: [Self.ground.r, Self.ground.g, Self.ground.b, 255], count: 100 * 100
            ).flatMap { $0 })
        let i = (50 * 100 + 50) * 4
        buffer.bytes[i] = Self.blue.r
        buffer.bytes[i + 1] = Self.blue.g
        buffer.bytes[i + 2] = Self.blue.b
        return EditorModel(
            original: buffer.makeImage(), document: EditDocument(scale: 1, salt: 7))
    }

    func map(_ m: EditorModel) -> RenderMap {
        Renderer.renderBase(m.original, edits: m.baseDocument).map
    }

    func pointer(_ m: EditorModel, _ x: Double, _ y: Double) -> Pointer {
        Pointer(rendered: CGPoint(x: x + 0.5, y: y + 0.5), map: map(m))
    }

    @Test func pickSetsSelectedAnnotationColour() {
        let m = model()
        m.apply { $0.annotations.append(note(1, CGRect(x: 5, y: 5, width: 20, height: 20))) }
        m.selection = .annotation(1)
        m.beginPickingColor()
        #expect(m.pickingColor)
        m.pick(at: pointer(m, 50, 50))
        #expect(!m.pickingColor)
        #expect(m.document.annotations[0].color == .sampled(Self.blue))
        m.undo()
        #expect(m.document.annotations[0].color == .initial)
    }

    @Test func pickReadsOriginalNotRender() {
        let m = model()
        m.apply {
            $0.annotations.append(
                Annotation(
                    id: 1, shape: .rectangle(rect: CGRect(x: 40, y: 40, width: 30, height: 30)),
                    color: .palette(.red)))
        }
        m.beginPickingColor()
        m.pick(at: pointer(m, 50, 50))
        #expect(m.style.color == .sampled(Self.blue))
        #expect(m.style.lastSampled == Self.blue)
    }

    @Test func pickBecomesStyleForNextAnnotation() {
        let m = model()
        var told: [AnnotationStyle] = []
        m.onStyleChange = { told.append($0) }
        m.beginPickingColor()
        m.mouseDown(pointer(m, 50, 50), map: map(m))  // a click while picking samples
        #expect(m.document.annotations.isEmpty)
        #expect(told.last?.lastSampled == Self.blue)
        m.tool = .rectangle
        let map = map(m)
        m.mouseDown(Pointer(rendered: CGPoint(x: 10, y: 10), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 30, y: 30), map: map), map: map, snap: false)
        m.mouseUp(Pointer(rendered: CGPoint(x: 30, y: 30), map: map), map: map, snap: false)
        #expect(m.document.annotations.last?.color == .sampled(Self.blue))
    }

    @Test func escapeCancelsPicking() {
        let m = model()
        m.beginPickingColor()
        m.cancelPickingColor()
        #expect(!m.pickingColor)
        #expect(m.style == .initial)
    }

    @Test func switchingToolEndsPicking() {
        let m = model()
        m.beginPickingColor()
        m.tool = .text
        #expect(!m.pickingColor)
    }

    @Test func aColourSetByHandStopsAPatchTrackingItsGround() {
        let m = model()
        m.apply {
            $0.annotations.append(
                Annotation(
                    id: 1,
                    shape: .patch(rect: CGRect(x: 5, y: 5, width: 20, height: 20), autoColor: true))
            )
        }
        m.selection = .annotation(1)
        m.setColor(.palette(.green))
        guard case .patch(_, let auto) = m.document.annotations[0].shape else { return }
        #expect(!auto)
        #expect(m.document.annotations[0].color == .palette(.green))
    }

    @Test func theBarOffersTheLastPickedColourOnceThereIsOne() {
        let m = model()
        m.apply { $0.annotations.append(note(1, CGRect(x: 5, y: 5, width: 20, height: 20))) }
        m.selection = .annotation(1)
        #expect(m.itemOptions?.first == .color(.initial, lastSampled: nil, picking: false))
        m.beginPickingColor()
        #expect(m.itemOptions?.first == .color(.initial, lastSampled: nil, picking: true))
        m.pick(at: pointer(m, 50, 50))
        #expect(
            m.itemOptions?.first
                == .color(.sampled(Self.blue), lastSampled: Self.blue, picking: false))
    }

    @Test func aSavedStyleWithoutASampleDecodes() throws {
        let style = AnnotationStyle(lastSampled: Self.blue)
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(AnnotationStyle.self, from: data) == style)
    }
}

@MainActor @Suite struct EyedropperBarTests {
    func segments(_ bar: ItemBar) -> NSSegmentedControl {
        func find(_ view: NSView) -> NSSegmentedControl? {
            if let found = view as? NSSegmentedControl { return found }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(bar)!
    }

    @Test func theSampleSwatchIsDisabledWithAReasonUntilOneIsPicked() {
        let bar = ItemBar()
        bar.show([.color(.initial)])
        let control = segments(bar)
        #expect(control.segmentCount == Palette.allCases.count + 1)
        #expect(!control.isEnabled(forSegment: Palette.allCases.count))
        #expect(
            control.toolTip(forSegment: Palette.allCases.count)
                == "Pick a colour with the eyedropper first")
    }

    @Test func aPickedSwatchAppliesItsColour() {
        let bar = ItemBar()
        var applied: [AnnotationColor] = []
        bar.onColor = { applied.append($0) }
        bar.show([.color(.initial, lastSampled: EyedropperTests.blue)])
        let control = segments(bar)
        let sample = Palette.allCases.count
        #expect(control.isEnabled(forSegment: sample))
        control.selectedSegment = sample
        _ = control.sendAction(control.action, to: control.target)
        #expect(applied == [.sampled(EyedropperTests.blue)])
    }
}
