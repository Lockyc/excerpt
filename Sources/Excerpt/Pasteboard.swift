import AppKit

@MainActor
enum Pasteboard {
    struct WriteFailed: Error, LocalizedError {
        var errorDescription: String? { "the pasteboard refused it" }
    }

    /// Puts the file's PNG on the clipboard, with TIFF for apps that only read TIFF.
    static func copyPNG(at url: URL) throws {
        try copyPNG(data: Data(contentsOf: url))
    }

    /// Puts plain text on the clipboard.
    static func copyText(_ text: String) throws {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw WriteFailed() }
    }

    /// Puts PNG data on the clipboard, with TIFF for apps that only read TIFF.
    static func copyPNG(data: Data) throws {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.png, .tiff], owner: nil)
        guard board.setData(data, forType: .png) else { throw WriteFailed() }
        if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
            board.setData(tiff, forType: .tiff)
        }
    }
}
