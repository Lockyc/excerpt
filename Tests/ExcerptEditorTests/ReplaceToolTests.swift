import AppKit
import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

@MainActor
@Suite struct ReplaceToolTests {
    static let scale = 2.0
    static let slate = RGBA(r: 0x27, g: 0x2C, b: 0x35, a: 255)
    static let gridline = RGBA(r: 0x45, g: 0x4B, b: 0x56, a: 255)
    static let white = RGBA(r: 255, g: 255, b: 255, a: 255)
    /// A table header's style: mono bold white, centred in its cell.
    static let header = TextStyle(points: 13, bold: true, font: .mono, alignment: .centered)

    /// Slate cells 320px wide and 80px tall between 1px gridlines.
    static let grid = Fixtures.paint(width: 961, height: 161) { x, y in
        x % 320 == 0 || y % 80 == 0 ? gridline : slate
    }

    /// "You" centred in the first header cell and "Name" in the second, drawn through Core's
    /// renderer, and the runs a recogniser would report for them: each one's ink, padded by 2px.
    static let (image, you, name): (CGImage, RecognizedText, RecognizedText) = {
        let texts = [("You", 160.0), ("Name", 480.0)].enumerated().map { i, text in
            Annotation(
                id: i + 1,
                shape: .text(
                    origin: CGPoint(x: text.1, y: 24), string: text.0, style: header),
                color: .sampled(white))
        }
        let image = Renderer.render(
            grid, edits: EditDocument(scale: scale, annotations: texts)
        ).image
        let drawn = PixelBuffer(image)
        let plain = PixelBuffer(grid)
        func run(_ string: String, columns: Range<Int>) -> RecognizedText {
            var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
            for y in 0..<drawn.height {
                for x in columns where drawn[x: x, y: y] != plain[x: x, y: y] {
                    (minX, minY) = (min(minX, x), min(minY, y))
                    (maxX, maxY) = (max(maxX, x), max(maxY, y))
                }
            }
            let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            return RecognizedText(string, box.insetBy(dx: -2, dy: -2))
        }
        return (image, run("You", columns: 1..<320), run("Name", columns: 321..<640))
    }()

    func model(runs: [RecognizedText]) async -> EditorModel {
        let m = EditorModel(
            original: Self.image, document: EditDocument(scale: Self.scale, salt: 5))
        m.tool = .replace
        await m.loadTextRuns(using: FixedRecognizer(runs: runs))
        return m
    }

    func patches(_ m: EditorModel) -> [CGRect] {
        m.document.annotations.compactMap {
            if case .patch(let rect, true) = $0.shape { return rect }
            return nil
        }
    }

    func texts(_ m: EditorModel) -> [String] {
        m.document.annotations.compactMap {
            if case .text(_, let string, _, _) = $0.shape { return string }
            return nil
        }
    }

    func near(_ a: RGBA, _ b: RGBA) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 8 && abs(Int(a.g) - Int(b.g)) <= 8
            && abs(Int(a.b) - Int(b.b)) <= 8
    }

    @Test func replaceOneCellMakesPatchAndPrefilledText() async throws {
        let m = await model(runs: [Self.you])
        m.replace(in: CGRect(x: Self.you.bounds.midX, y: Self.you.bounds.midY, width: 0, height: 0))
        #expect(m.document.annotations.count == 2)
        let patch = m.document.annotations[0]
        guard case .patch(let rect, true) = patch.shape else {
            Issue.record("no auto-coloured patch")
            return
        }
        #expect(patch.color == .sampled(Self.slate))
        // Over all the ink and a point's pixel around it, inside the cell.
        let ink = Self.you.bounds.insetBy(dx: 2, dy: 2)
        #expect(rect.contains(ink.insetBy(dx: -1, dy: -1)), "patch \(rect) vs ink \(ink)")
        #expect(ink.insetBy(dx: -Self.scale, dy: -Self.scale).contains(rect), "patch \(rect)")
        #expect(rect.minX > 0 && rect.maxX <= 320 && rect.minY > 0 && rect.maxY <= 80)

        let text = m.document.annotations[1]
        guard case .text(let origin, let string, let background, let style?) = text.shape else {
            Issue.record("no styled text")
            return
        }
        #expect(string == "You")
        // On the cell's centre, where the header was drawn.
        #expect(abs(Double(origin.x) - 160) <= 1, "origin.x \(origin.x)")
        #expect(background == false)
        #expect(style.alignment == .centered)
        #expect(style.font == .mono)
        #expect(style.bold)
        #expect(near(text.color.rgba, Self.white), "colour \(text.color.rgba)")

        // Typing opens on it, the whole string selected.
        #expect(m.typing?.id == text.id)
        #expect(m.typedString == "You")
        #expect(m.selectsTypedString)
        #expect(m.selection == .annotation(text.id))

        m.endTyping()
        #expect(m.document.annotations.count == 2)
        m.undo()
        #expect(m.document.annotations.isEmpty)
    }

    @Test func replaceAcrossCellsMakesOnePairPerRun() async throws {
        // Reported out of reading order: typing still opens on the first in it.
        let m = await model(runs: [Self.name, Self.you])
        let across = Self.you.bounds.union(Self.name.bounds).insetBy(dx: 10, dy: 4)
        m.replace(in: across)
        #expect(m.document.annotations.count == 4)
        #expect(Set(texts(m)) == ["You", "Name"])
        let rects = patches(m)
        #expect(rects.count == 2)
        // Neither crosses the gridline between the cells.
        for rect in rects { #expect(rect.maxX <= 320 || rect.minX > 320, "patch \(rect)") }
        #expect(m.typedString == "You")
        m.endTyping()
        m.undo()
        #expect(m.document.annotations.isEmpty)
    }

    @Test func replaceOnNothingMakesPatchAndEmptyText() async throws {
        let m = await model(runs: [])
        let rect = CGRect(x: 20, y: 100, width: 120, height: 30)
        m.replace(in: rect)
        #expect(m.document.annotations.count == 1)
        let patch = m.document.annotations[0]
        #expect(patch.shape == .patch(rect: rect, autoColor: true))
        #expect(patch.color == .sampled(Self.slate))
        let typing = try #require(m.typing)
        #expect(
            typing.shape
                == .text(
                    origin: CGPoint(x: rect.minX, y: rect.minY), string: "",
                    background: m.style.background))
        #expect(typing.color == m.style.color)
        #expect(m.replaceNote == "No text found")
        // A change of tool clears the note.
        m.tool = .select
        #expect(m.replaceNote == "")
    }

    @Test func aClickOnNothingMakesNoPatch() async throws {
        let m = await model(runs: [])
        m.replace(in: CGRect(x: 40, y: 120, width: 0, height: 0))
        #expect(m.document.annotations.isEmpty)
        #expect(
            m.typing?.shape
                == .text(
                    origin: CGPoint(x: 40, y: 120), string: "", background: m.style.background))
        #expect(m.replaceNote == "No text found")
    }

    @Test func replaceWaitsForRuns() async throws {
        let m = EditorModel(
            original: Self.image, document: EditDocument(scale: Self.scale, salt: 5))
        m.tool = .replace
        let load = m.startLoadingTextRuns(using: FixedRecognizer(runs: [Self.you]))
        m.replace(in: Self.you.bounds)
        #expect(m.document.annotations.isEmpty)
        #expect(m.isTypingPending)
        await load.value
        #expect(!m.isTypingPending)
        #expect(m.document.annotations.count == 2)
        #expect(m.typedString == "You")
    }

    @Test func aToolChangeDropsAPendingReplace() async {
        let m = EditorModel(
            original: Self.image, document: EditDocument(scale: Self.scale, salt: 5))
        m.tool = .replace
        let load = m.startLoadingTextRuns(using: FixedRecognizer(runs: [Self.you]))
        m.replace(in: Self.you.bounds)
        m.tool = .arrow
        await load.value
        #expect(!m.isTypingPending)
        #expect(m.document.annotations.isEmpty)
        #expect(m.typing == nil)
    }

    @Test func aDragUnderTheToolReplaces() async {
        let m = await model(runs: [Self.you])
        let map = Renderer.renderBase(m.original, edits: m.baseDocument).map
        let b = Self.you.bounds
        m.mouseDown(Pointer(rendered: CGPoint(x: b.minX, y: b.minY), map: map), map: map)
        let end = Pointer(rendered: CGPoint(x: b.maxX, y: b.maxY), map: map)
        m.mouseDragged(end, map: map, snap: false)
        m.mouseUp(end, map: map, snap: false)
        #expect(patches(m).count == 1)
        #expect(m.typedString == "You")
    }

    @Test func replaceToolIsOnX() {
        #expect(Tool(key: "x") == .replace)
        #expect(Tool.replace.title == "Replace")
        #expect(Tool.replace.symbol == "character.cursor.ibeam")
    }

    @Test func theCanvasOpensTypingWithTheStringSelected() async throws {
        let m = await model(runs: [Self.you])
        let canvas = CanvasView(model: m)
        canvas.zoom = 0.5
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = canvas
        window.contentView!.addSubview(scroll)
        let g = CanvasView.gutter * Self.scale
        let at = CGPoint(
            x: (Self.you.bounds.midX + g) * canvas.zoom, y: (Self.you.bounds.midY + g) * canvas.zoom
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: canvas.convert(at, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown {
                canvas.mouseDown(with: event)
            } else {
                canvas.mouseUp(with: event)
            }
        }
        let view = try #require(window.firstResponder as? NSTextView)
        #expect(view.string == "You")
        #expect(view.selectedRange() == NSRange(location: 0, length: 3))
    }
}
