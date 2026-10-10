import AppKit
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

    /// The editor's current image could not be put on the clipboard.
    static func copyFailed(_ file: URL, _ error: Error) {
        show(
            "Couldn't copy to the clipboard",
            "Excerpt couldn't copy \(file.lastPathComponent): \(error.localizedDescription).")
    }

    /// A file the editor can't open: not a PNG, unreadable, damaged, or edited by a newer Excerpt.
    static func openFailed(_ file: URL, _ error: Error) {
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
