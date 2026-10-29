import AppKit
import ExcerptCapture
import ExcerptCore
import ExcerptExport

@MainActor
enum Alerts {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// `text` closed with a full stop, unless it already ends in punctuation: error
    /// descriptions arrive both ways.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
    }

    /// The library folder can't be created or written; names the path so the fix is obvious.
    static func libraryUnwritable(_ folder: URL, _ error: Error) {
        show(
            "Couldn't use the library folder",
            sentence("Excerpt couldn't write to \(folder.path): \(error.localizedDescription)")
                + " Choose another library folder in Settings."
        )
    }

    /// The captured pixels could not be encoded as a PNG; nothing was written.
    static func encodeFailed(_ error: Error) {
        show(
            "Couldn't encode the capture",
            sentence("Excerpt couldn't make a PNG from the capture: \(error)")
        )
    }

    /// The capture is saved but could not be put on the clipboard.
    static func clipboardFailed(_ file: URL, _ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            sentence(
                "The capture is saved as \(file.lastPathComponent), but Excerpt couldn't read it back to copy: \(error.localizedDescription)"
            )
        )
    }

    enum AccessibilityChoice { case openSettings, scrollYourself, cancel }

    /// Accessibility isn't granted, so Excerpt can't scroll the page: open the setting, scroll
    /// the page by hand while Excerpt stitches, or cancel.
    static func accessibilityNeeded() -> AccessibilityChoice {
        let alert = NSAlert()
        alert.messageText = "Excerpt needs Accessibility to scroll the page for you."
        alert.informativeText =
            "Turn on Excerpt under Privacy & Security → Accessibility, or scroll the page yourself while Excerpt stitches it."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Scroll It Myself")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openSettings
        case .alertSecondButtonReturn: return .scrollYourself
        default: return .cancel
        }
    }

    /// Captures old enough to file stayed at the top of the library.
    static func libraryNotFiled(_ failures: [LibraryFilingFailure]) {
        show(
            "Couldn't file some captures",
            sentence(
                "Excerpt files captures into month folders, but left "
                    + failures.map(\.description).joined(separator: "; "))
                + " Move or rename them in Finder.")
    }

    /// The library couldn't be read, so nothing in it could be filed.
    static func libraryUnfileable(_ folder: URL, _ error: Error) {
        show(
            "Couldn't file captures",
            sentence(
                "Excerpt files captures into month folders, but couldn't read \(folder.path): \(error.localizedDescription)"
            ))
    }

    /// Capture Text recognised the selection's text but could not put it on the clipboard, which
    /// was cleared for it.
    static func textCopyFailed(_ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            sentence(
                "Excerpt read the text but couldn't copy it, and the clipboard is now empty: \(error.localizedDescription)"
            ))
    }

    /// Capture Text could not read the selection's text.
    static func textUnreadable(_ error: Error) {
        show("Couldn't read the text", sentence(error.localizedDescription))
    }

    /// The editor's current image could not be put on the clipboard.
    static func copyFailed(_ file: URL, _ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            sentence(
                "Excerpt couldn't copy \(file.lastPathComponent): \(error.localizedDescription)"))
    }

    /// A file the editor can't open: not an image, unreadable, too large, damaged, or edited by
    /// a newer Excerpt. The title names the file at fault.
    static func openFailed(_ opened: URL, _ error: Error) {
        var file = opened
        var error = error
        if let unreadable = error as? MasterUnreadable {
            (file, error) = (unreadable.file, unreadable.underlying)
        }
        let reason: String
        switch error {
        case let limits as EditLimitsError:
            file = URL(fileURLWithPath: limits.path)
            reason = limits.reason
        case is PNGError: reason = "It isn't a PNG Excerpt can read."
        default: reason = sentence(error.localizedDescription)
        }
        show("Couldn't open \(file.lastPathComponent)", reason)
    }
}

/// A scrolling capture's own failures, said in its HUD where the user is looking, not an alert.
@MainActor
extension ScrollHUDText {
    /// The region couldn't be streamed, so nothing was captured.
    static func couldNotStart(_ error: Error) -> ScrollHUDText {
        ScrollHUDText(
            title: "Couldn't start the scrolling capture",
            detail: Alerts.sentence(error.localizedDescription), tone: .attention)
    }

    /// A scrolling capture ended part-way, because its stream stopped or the displays changed;
    /// says whether what was stitched is saved.
    static func stopped(_ error: Error, savedPartial: Bool) -> ScrollHUDText {
        let cause =
            error as? ScrollCaptureError == .displayChanged
            ? "The displays changed, so the capture ended."
            : Alerts.sentence(
                "Excerpt lost the picture of the region: \(error.localizedDescription)")
        return ScrollHUDText(
            title: "Scrolling capture stopped",
            detail: cause + " "
                + (savedPartial ? "What was stitched before that is saved." : "Nothing was saved."),
            tone: .attention)
    }

    /// The region's screen recording could not be stopped after a scrolling capture ended.
    static func recordingNotStopped(_ error: Error, saved: Bool) -> ScrollHUDText {
        ScrollHUDText(
            title: "Couldn't stop recording the region",
            detail: Alerts.sentence(
                "Excerpt couldn't stop recording the screen: \(error.localizedDescription)")
                + (saved ? " The capture is saved." : ""), tone: .attention)
    }
}
