import AppKit
import ExcerptCapture
import ExcerptCore

@MainActor
enum Alerts {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The library folder can't be created or written; names the path so the fix is obvious.
    static func libraryUnwritable(_ folder: URL, _ error: Error) {
        show(
            "Couldn't use the library folder",
            "Excerpt couldn't write to \(folder.path): \(error.localizedDescription). Choose another library folder in Settings."
        )
    }

    /// The captured pixels could not be encoded as a PNG; nothing was written.
    static func encodeFailed(_ error: Error) {
        show(
            "Couldn't encode the capture", "Excerpt couldn't make a PNG from the capture: \(error)."
        )
    }

    /// The capture is saved but could not be put on the clipboard.
    static func clipboardFailed(_ file: URL, _ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            "The capture is saved as \(file.lastPathComponent), but Excerpt couldn't read it back to copy: \(error.localizedDescription)."
        )
    }

    /// A scrolling capture ended part-way, because its stream stopped or the displays changed;
    /// says whether what was stitched is saved.
    static func scrollingStopped(_ error: Error, savedPartial: Bool) {
        let cause =
            error as? ScrollCaptureError == .displayChanged
            ? "The displays changed, so the capture ended."
            : "Excerpt lost the picture of the region: \(error.localizedDescription)"
        show(
            "Scrolling capture stopped",
            cause + " "
                + (savedPartial
                    ? "What was stitched before that is saved." : "Nothing was saved."))
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

    /// The region's screen recording could not be stopped after a scrolling capture ended.
    static func recordingNotStopped(_ error: Error, saved: Bool) {
        show(
            "Couldn't stop recording the region",
            "Excerpt couldn't stop recording the screen: \(error.localizedDescription)."
                + (saved ? " The capture is saved." : ""))
    }

    /// The editor's current image could not be put on the clipboard.
    static func copyFailed(_ file: URL, _ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            "Excerpt couldn't copy \(file.lastPathComponent): \(error.localizedDescription).")
    }

    /// A file the editor can't open: not a PNG, unreadable, damaged, or edited by a newer Excerpt.
    static func openFailed(_ opened: URL, _ error: Error) {
        var file = opened
        var error = error
        if let unreadable = error as? MasterUnreadable {
            (file, error) = (unreadable.file, unreadable.underlying)
        }
        let reason: String
        switch error {
        case EditDocumentError.unsupportedVersion:
            reason = "It was edited by a newer version of Excerpt."
        case EditDocumentError.invalidScale, EditDocumentError.invalidGeometry,
            EditDocumentError.damaged:
            reason = "Its saved edits are damaged."
        case is PNGError:
            reason = "It isn't a PNG Excerpt can read."
        default:
            reason = error.localizedDescription
        }
        show("Couldn't open \(file.lastPathComponent)", reason)
    }
}
