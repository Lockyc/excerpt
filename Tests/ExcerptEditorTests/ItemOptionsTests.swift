import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

@Suite struct ItemOptionsTests {
    func model() -> EditorModel {
        EditorModel(
            original: Fixtures.sheet(width: 360, height: 400),
            document: EditDocument(scale: 1, salt: 7))
    }

    func options(_ shape: Shape) -> [ItemOption] {
        EditorModel.options(
            for: Annotation(id: 1, shape: shape, color: .blue, width: .thick),
            canMoveEarlier: true, canMoveLater: false)
    }

    @Test func eachKindTakesOnlyItsOwnOptions() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(
            options(.arrow(tail: .zero, head: CGPoint(x: 9, y: 9)))
                == [.color(.blue), .size(.thick), .delete])
        #expect(options(.rectangle(rect: r)) == [.color(.blue), .size(.thick), .delete])
        #expect(options(.highlight(rect: r)) == [.color(.blue), .delete])
        #expect(options(.blur(rect: r)) == [.delete])
        #expect(
            options(.text(origin: .zero, string: "a", background: true))
                == [.color(.blue), .size(.thick), .background(true), .delete])
        #expect(
            options(.text(origin: .zero, string: "a"))
                == [.color(.blue), .size(.thick), .background(false), .delete])
        #expect(
            options(.step(center: .zero))
                == [
                    .color(.blue), .size(.thick), .moveEarlier(enabled: true),
                    .moveLater(enabled: false), .delete,
                ])
    }

    @Test func theBarFollowsTypingSelectionAndCrop() {
        let m = model()
        #expect(m.itemOptions == nil)
        m.apply { $0.cuts = [Cut(axis: .horizontal, lower: 100, upper: 200)] }
        m.selection = .seam(.horizontal, 100..<200)
        #expect(m.itemOptions == [.delete])
        m.selection = nil
        m.tool = .crop
        #expect(m.itemOptions == nil)
        m.apply { $0.crop = PixelRect(x: 0, y: 0, width: 100, height: 100) }
        #expect(m.itemOptions == [.delete])
        m.tool = .text
        let map = Renderer.renderBase(m.original, edits: m.baseDocument).map
        m.beginTyping(at: Pointer(rendered: CGPoint(x: 40, y: 40), map: map), map: map)
        #expect(m.itemOptions == [.color(.initial), .size(.initial), .background(true), .delete])
    }
}
