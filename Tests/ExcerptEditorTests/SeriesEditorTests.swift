import AppKit
import ExcerptTestSupport
import Testing

@testable import ExcerptCore
@testable import ExcerptEditor

@MainActor
@Suite struct SeriesEditorTests {
    /// Opens once; `wait` returns at once after that.
    final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var isOpen = false

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    final class Calls {
        var saved: [URL] = []
        var copied: [Data] = []
        let saving = Gate()
        /// Each save waits on it before it returns.
        let release = Gate()
        let copiedAll = Gate()
        var closed = false

        init(holdingSaves: Bool = false) {
            if !holdingSaves { release.open() }
        }
    }

    func series(_ count: Int = 3, calls: Calls = Calls()) -> EditorWindowController {
        let captures = (0..<count).map { i in
            LoadedCapture(
                primary: URL(fileURLWithPath: "/tmp/probe-\(i).png"),
                original: Fixtures.sheet(width: 400, height: 300),
                edits: EditDocument(scale: 1, salt: UInt64(i)), supersedesMaster: false)
        }
        return EditorWindowController(
            captures: captures,
            save: { capture, _ in
                calls.saved.append(capture.primary)
                calls.saving.open()
                await calls.release.wait()
                return Data([UInt8(calls.saved.count)])
            },
            copy: { make in
                calls.copied = (try? make()) ?? []
                calls.copiedAll.open()
                return true
            },
            forClaude: { _, _, _ in }, borderStyle: .initial, rememberBorder: { _ in },
            annotationStyle: .initial, rememberStyle: { _ in }, onClose: { calls.closed = true })
    }

    func addStep(to editor: EditorWindowController, at index: Int) {
        let model = editor.model(at: index)
        model.apply { doc in
            doc.annotations.append(
                Annotation(
                    id: doc.nextAnnotationID, shape: .step(center: CGPoint(x: 50, y: 50))))
        }
    }

    @Test func switchingKeepsTheToolAndStyle() {
        let editor = series()
        defer { editor.window?.orderOut(nil) }
        editor.model(at: 0).tool = .step
        editor.show(capture: 1)
        #expect(editor.current == 1)
        #expect(editor.model(at: 1).tool == .step)
    }

    @Test func stepsCarryOn() {
        let editor = series()
        defer { editor.window?.orderOut(nil) }
        addStep(to: editor, at: 0)
        addStep(to: editor, at: 1)
        addStep(to: editor, at: 1)
        #expect(editor.model(at: 1).document.firstStep == 2)
        #expect(editor.model(at: 2).document.firstStep == 1)
        addStep(to: editor, at: 2)
        #expect(editor.model(at: 2).document.firstStep == 4)
    }

    @Test func aRestartResetsLaterCaptures() {
        let editor = series()
        defer { editor.window?.orderOut(nil) }
        for i in 0..<3 { addStep(to: editor, at: i) }
        addStep(to: editor, at: 1)
        editor.model(at: 1).setRestartsSteps(true)
        #expect(editor.model(at: 1).document.firstStep == 1)
        #expect(editor.model(at: 2).document.firstStep == 3)
    }

    @Test func renumberingLeavesAStepLessCaptureClean() {
        let editor = series()
        defer { editor.window?.orderOut(nil) }
        addStep(to: editor, at: 0)
        #expect(!editor.model(at: 2).isDirty)
    }

    @Test func undoOnALaterCaptureKeepsItsNumbering() {
        let editor = series()
        defer { editor.window?.orderOut(nil) }
        addStep(to: editor, at: 0)
        addStep(to: editor, at: 1)
        editor.model(at: 1).undo()
        editor.model(at: 1).redo()
        #expect(editor.model(at: 1).document.firstStep == 2)
        editor.model(at: 0).undo()
        #expect(editor.model(at: 1).document.firstStep == 1)
    }

    @Test func saveWritesOnlyChangedCapturesAndCopiesEveryRenderInOrder() async {
        let calls = Calls()
        let editor = series(calls: calls)
        defer { editor.window?.orderOut(nil) }
        addStep(to: editor, at: 1)
        editor.saveDocument()
        await calls.copiedAll.wait()
        #expect(calls.saved == [URL(fileURLWithPath: "/tmp/probe-1.png")])
        #expect(calls.copied.count == 3)
        #expect(calls.copied[1] == Data([1]))
        await Task.yield()
        #expect(calls.closed)
    }

    /// The save writes the document as it was when Save was pressed; an edit made while it
    /// writes stays unsaved, so the window stays open with it.
    @Test func anEditWhileSavingStaysUnsavedAndKeepsTheWindowOpen() async {
        let calls = Calls(holdingSaves: true)
        let editor = series(calls: calls)
        defer { editor.window?.orderOut(nil) }
        addStep(to: editor, at: 0)
        editor.saveDocument()
        await calls.saving.wait()
        addStep(to: editor, at: 0)
        calls.release.open()
        await calls.copiedAll.wait()
        await Task.yield()
        #expect(editor.model(at: 0).isDirty)
        #expect(!calls.closed)
        editor.model(at: 0).undo()
        #expect(!editor.model(at: 0).isDirty)
    }

    /// While a save writes, the window won't close and a quit's confirmation answers no
    /// without asking.
    @Test func closingWaitsForASaveInFlight() async throws {
        let calls = Calls(holdingSaves: true)
        let editor = series(calls: calls)
        defer { editor.window?.orderOut(nil) }
        let window = try #require(editor.window)
        addStep(to: editor, at: 0)
        editor.saveDocument()
        await calls.saving.wait()
        #expect(editor.hasUnsavedChanges())
        #expect(!editor.windowShouldClose(window))
        var answer: Bool?
        editor.confirmClose { answer = $0 }
        #expect(answer == false)
        calls.release.open()
        await calls.copiedAll.wait()
        await Task.yield()
        #expect(calls.closed)
        #expect(!editor.hasUnsavedChanges())
        #expect(calls.saved.count == 1)
    }

    @Test func theBracketKeysMoveBetweenCapturesAndStopAtTheEnds() throws {
        let editor = series()
        defer { editor.window?.orderOut(nil) }
        let window = try #require(editor.window)
        func press(_ key: String) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            _ = window.performKeyEquivalent(with: event)
        }
        press("[")
        #expect(editor.current == 0)
        press("]")
        press("]")
        press("]")
        #expect(editor.current == 2)
        press("[")
        #expect(editor.current == 1)
    }

    @Test func aSingleCaptureHasNoFilmstrip() {
        let editor = series(1)
        defer { editor.window?.orderOut(nil) }
        #expect(!hasFilmstrip(editor.window?.contentView))
        let pair = series(2)
        defer { pair.window?.orderOut(nil) }
        #expect(hasFilmstrip(pair.window?.contentView))
    }

    func hasFilmstrip(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is Filmstrip || view.subviews.contains { hasFilmstrip($0) }
    }
}

@MainActor
@Suite struct FilmstripTests {
    @Test func labelsNameTheSteps() {
        #expect(Filmstrip.label(first: 1, count: 0) == "No steps")
        #expect(Filmstrip.label(first: 3, count: 1) == "Step 3")
        #expect(Filmstrip.label(first: 3, count: 2) == "Steps 3–4")
    }

    @Test func restartIsDisabledWithoutStepsAndOnTheFirstCapture() {
        let strip = Filmstrip(count: 2)
        strip.setSteps(first: 1, count: 0, restarts: false, at: 1)
        #expect(!strip.restartSwitch(at: 1).isEnabled)
        strip.setSteps(first: 2, count: 1, restarts: false, at: 1)
        #expect(strip.restartSwitch(at: 1).isEnabled)
        strip.setSteps(first: 1, count: 2, restarts: false, at: 0)
        #expect(!strip.restartSwitch(at: 0).isEnabled)
    }
}

@MainActor
@Suite struct SeriesEditorFixTests {
    func editor(_ docs: [EditDocument], height: (Int) -> Int = { _ in 300 })
        -> EditorWindowController
    {
        let captures = docs.enumerated().map { i, doc in
            LoadedCapture(
                primary: URL(fileURLWithPath: "/tmp/fix-\(i).png"),
                original: Fixtures.sheet(width: 400, height: height(i)), edits: doc,
                supersedesMaster: false)
        }
        return EditorWindowController(
            captures: captures, save: { _, _ in Data() }, copy: { _ in true },
            forClaude: { _, _, _ in }, borderStyle: .initial, rememberBorder: { _ in },
            annotationStyle: .initial, rememberStyle: { _ in }, onClose: {})
    }

    @Test func aLoneCaptureKeepsTheNumbersItWasSavedWith() {
        let step = Annotation(id: 1, shape: .step(center: CGPoint(x: 50, y: 50)))
        let lone = editor([EditDocument(scale: 1, annotations: [step], firstStep: 4, salt: 1)])
        defer { lone.window?.orderOut(nil) }
        #expect(lone.model(at: 0).document.firstStep == 4)
        #expect(!lone.model(at: 0).isDirty)
    }

    @Test func switchingMidDragEndsTheDrag() {
        let pair = editor([EditDocument(scale: 1, salt: 1), EditDocument(scale: 1, salt: 2)])
        defer { pair.window?.orderOut(nil) }
        let m = pair.model(at: 0)
        m.tool = .rectangle
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 400, height: 300),
            rows: AxisMap(extent: 300, bands: [], gap: 36),
            columns: AxisMap(extent: 400, bands: [], gap: 36))
        m.mouseDown(Pointer(rendered: CGPoint(x: 10, y: 10), map: map), map: map)
        m.mouseDragged(Pointer(rendered: CGPoint(x: 90, y: 90), map: map), map: map, snap: false)
        #expect(m.drag != nil)
        pair.show(capture: 1)
        #expect(m.drag == nil)
    }

    @Test func switchingToATallerCaptureKeepsTheWindowOnScreen() throws {
        let pair = editor(
            [EditDocument(scale: 1, salt: 1), EditDocument(scale: 1, salt: 2)],
            height: { $0 == 0 ? 200 : 3000 })
        defer { pair.window?.orderOut(nil) }
        let window = try #require(pair.window)
        let visible = try #require(window.screen ?? NSScreen.main).visibleFrame
        window.setFrameTopLeftPoint(CGPoint(x: visible.minX, y: visible.minY + 350))
        pair.show(capture: 1)
        #expect(window.frame.minY >= visible.minY)
    }
}
