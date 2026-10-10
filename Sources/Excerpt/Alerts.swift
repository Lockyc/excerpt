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

    /// The For Claude bundle could not be built: the cache, or text recognition, failed.
    static func claudeExportFailed(_ name: String, _ error: Error) {
        show("Couldn't prepare \(name) for Claude", error.localizedDescription + ".")
    }

    /// The For Claude bundle is written but its references could not go on the clipboard.
    static func claudeCopyFailed(_ folder: URL, _ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            "The tiles and text.md are in \(folder.path), but Excerpt couldn't copy their references: \(error.localizedDescription)."
        )
    }

    /// Expired For Claude bundles stayed in the cache; the export itself went through.
    static func claudeCacheNotPruned(_ failures: [ClaudeCacheError]) {
        let days = Int(ClaudeCache.maximumAge / (24 * 60 * 60))
        show(
            "Couldn't remove old Claude bundles",
            "Excerpt removes For Claude bundles after \(days) days, but couldn't remove "
                + failures.map(\.description).joined(separator: "; ")
                + ". Remove them in Finder.")
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
        let reason =
            error is PNGError ? "It isn't a PNG Excerpt can read." : error.localizedDescription
        show("Couldn't open \(file.lastPathComponent)", reason)
    }
}
