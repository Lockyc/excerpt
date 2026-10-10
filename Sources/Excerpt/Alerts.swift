import AppKit

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
}
