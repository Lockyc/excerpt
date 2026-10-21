import AppKit
import ExcerptTestSupport
import Testing

@testable import ExcerptCore
@testable import ExcerptEditor

@MainActor
@Suite struct SeriesEditorTests {
    final class Calls {
        var saved: [URL] = []
        var copied: [Data] = []
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
                return Data([UInt8(calls.saved.count)])
            },
            copy: { make in
                calls.copied = (try? make()) ?? []
                return true
            },
            forClaude: { _, _, _ in }, borderStyle: .initial, rememberBorder: { _ in },
            annotationStyle: .initial, rememberStyle: { _ in }, onClose: {})
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

    @Test func saveWritesOnlyChangedCapturesAndCopiesEveryRenderInOrder() {
        let calls = Calls()
        let editor = series(calls: calls)
        defer { editor.window?.orderOut(nil) }
        addStep(to: editor, at: 1)
        editor.saveDocument()
        #expect(calls.saved == [URL(fileURLWithPath: "/tmp/probe-1.png")])
        #expect(calls.copied.count == 3)
        #expect(calls.copied[1] == Data([1]))
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
