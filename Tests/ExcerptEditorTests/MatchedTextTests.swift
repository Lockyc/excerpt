import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptEditor

/// A recogniser that reports `runs` for any image.
struct FixedRecognizer: TextRecognizer {
    let runs: [RecognizedText]
    func recognize(_ image: CGImage) throws -> [RecognizedText] { runs }
}

struct FailingRecognizer: TextRecognizer {
    struct Failure: Error {}
    func recognize(_ image: CGImage) throws -> [RecognizedText] { throw Failure() }
}

@MainActor
@Suite struct MatchedTextTests {
    static let scale = 2.0
    static let image = TextFixtures.page(["Hello world"], width: 200, scale: scale)

    /// The run a recogniser would report for the fixture's line: its ink's box, padded by 2px.
    static let run: RecognizedText = {
        let buffer = PixelBuffer(image)
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where buffer[x: x, y: y].r < 200 {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return RecognizedText("Hello world", box.insetBy(dx: -2, dy: -2))
    }()

    func model() -> EditorModel {
        let m = EditorModel(
            original: Self.image, document: EditDocument(scale: Self.scale, salt: 7))
        m.tool = .text
        return m
    }

    func map(_ m: EditorModel) -> RenderMap {
        Renderer.renderBase(m.original, edits: m.baseDocument).map
    }

    func pointer(_ m: EditorModel, _ p: CGPoint) -> Pointer {
        Pointer(rendered: p, map: map(m))
    }

    var onText: CGPoint { CGPoint(x: Self.run.bounds.midX, y: Self.run.bounds.midY) }
    /// Right of the line, clear of its run.
    var offText: CGPoint { CGPoint(x: Self.run.bounds.maxX + 20, y: Self.run.bounds.midY) }

    @Test func clickOnRecognisedTextStartsMatched() async throws {
        let m = model()
        await m.loadTextRuns(using: FixedRecognizer(runs: [Self.run]))
        #expect(m.textRuns == [Self.run])
        m.beginTyping(at: pointer(m, onText), map: map(m))
        let expected = try #require(
            TextMatcher.match(Self.run, in: PixelBuffer(Self.image), scale: Self.scale))
        let typing = try #require(m.typing)
        guard case .text(let origin, let string, let background, let style) = typing.shape else {
            Issue.record("not text")
            return
        }
        #expect(origin == expected.origin)
        #expect(string == "")
        #expect(background == false)
        #expect(style == expected.style)
        #expect(typing.color == expected.color)
    }

    @Test func clickOnPlainAreaKeepsLastStyle() async throws {
        let m = model()
        await m.loadTextRuns(using: FixedRecognizer(runs: [Self.run]))
        let before = m.style
        m.beginTyping(at: pointer(m, onText), map: map(m))
        m.updateTyping("matched")
        m.endTyping()
        // Matching the text under the click is not a choice of style for what comes next.
        #expect(m.style == before)
        let p = pointer(m, offText)
        m.beginTyping(at: p, map: map(m))
        let typing = try #require(m.typing)
        #expect(
            typing.shape == .text(origin: p.original, string: "", background: before.background))
        #expect(typing.color == before.color)
        #expect(typing.width == before.width)
    }

    @Test func throwingRecognizerFallsBackToPlainText() async throws {
        let m = model()
        await m.loadTextRuns(using: FailingRecognizer())
        #expect(m.textRuns == [])
        let p = pointer(m, onText)
        m.beginTyping(at: p, map: map(m))
        let typing = try #require(m.typing)
        #expect(
            typing.shape == .text(origin: p.original, string: "", background: m.style.background))
    }

    @Test func aBeginBeforeTheRunsAreReadWaitsForThem() async throws {
        let m = model()
        let load = m.startLoadingTextRuns(using: FixedRecognizer(runs: [Self.run]))
        m.beginTyping(at: pointer(m, onText), map: map(m))
        #expect(m.typing == nil)
        #expect(m.isTypingPending)
        await load.value
        #expect(!m.isTypingPending)
        let expected = try #require(
            TextMatcher.match(Self.run, in: PixelBuffer(Self.image), scale: Self.scale))
        guard case .text(_, _, _, let style)? = m.typing?.shape else {
            Issue.record("no text")
            return
        }
        #expect(style == expected.style)
    }

    @Test func changingToolDropsAPendingBegin() async {
        let m = model()
        let load = m.startLoadingTextRuns(using: FixedRecognizer(runs: [Self.run]))
        m.beginTyping(at: pointer(m, onText), map: map(m))
        m.tool = .arrow
        await load.value
        #expect(m.typing == nil)
        #expect(!m.isTypingPending)
    }

    @Test func freeSizeSetsPoints() throws {
        let m = model()
        m.beginTyping(at: pointer(m, offText), map: map(m))
        m.setTextSize(17.5)
        guard case .text(_, _, _, let style)? = m.typing?.shape else {
            Issue.record("no text")
            return
        }
        #expect(style == TextStyle(points: 17.5))
        // Held to the sizes a text may have.
        m.setTextSize(500)
        guard case .text(_, _, _, let clamped)? = m.typing?.shape else { return }
        #expect(clamped?.points == TextStyle.pointsRange.upperBound)
        // A preset sets the styled text's size too.
        m.setWidth(.thin)
        guard case .text(_, _, _, let preset)? = m.typing?.shape else { return }
        #expect(preset?.points == StrokeWidth.thin.textPoints)
    }

    @Test func legacyTextMaterialisesStyleOnFirstChange() {
        let m = model()
        m.apply {
            $0.annotations.append(
                Annotation(
                    id: 1, shape: .text(origin: CGPoint(x: 10, y: 10), string: "Old"),
                    color: .palette(.red), width: .thick))
        }
        m.tool = .select
        m.selection = .annotation(1)
        m.setBold(false)
        #expect(
            m.document.annotations[0].shape
                == .text(
                    origin: CGPoint(x: 10, y: 10), string: "Old",
                    style: TextStyle(points: StrokeWidth.thick.textPoints, bold: false)))
        m.setFont(.mono)
        m.setTextSize(33)
        #expect(
            m.document.annotations[0].shape
                == .text(
                    origin: CGPoint(x: 10, y: 10), string: "Old",
                    style: TextStyle(points: 33, bold: false, font: .mono)))
        m.undo()
        m.undo()
        m.undo()
        #expect(
            m.document.annotations[0].shape == .text(origin: CGPoint(x: 10, y: 10), string: "Old"))
    }

    @Test func alignmentKeepsTheTextInPlace() throws {
        let m = model()
        m.apply {
            $0.annotations.append(
                Annotation(
                    id: 1,
                    shape: .text(
                        origin: CGPoint(x: 10, y: 10), string: "Wide line",
                        style: TextStyle(points: 20)),
                    color: .palette(.red)))
        }
        m.tool = .select
        m.selection = .annotation(1)
        let before = try #require(
            AnnotationGeometry.textRect(of: m.document.annotations[0], scale: Self.scale))
        m.setAlignment(.centered)
        let after = try #require(
            AnnotationGeometry.textRect(of: m.document.annotations[0], scale: Self.scale))
        guard case .text(_, _, _, let style) = m.document.annotations[0].shape else { return }
        #expect(style?.alignment == .centered)
        #expect(abs(after.minX - before.minX) < 0.001)
    }
}
