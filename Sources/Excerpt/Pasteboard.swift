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

    /// The provider of the TIFF on the clipboard now, held until the pasteboard is done with it.
    private static var tiffProvider: TIFFProvider?

    /// Puts PNG data on the clipboard, with TIFF for apps that only read TIFF. The TIFF is made
    /// only when such an app asks for it: converting a full-screen capture costs over 100ms.
    static func copyPNG(data: Data) throws {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        let provider = TIFFProvider(png: data)
        guard item.setData(data, forType: .png),
            item.setDataProvider(provider, forTypes: [.tiff]),
            board.writeObjects([item])
        else { throw WriteFailed() }
        tiffProvider = provider
    }

    fileprivate static func finished(with provider: TIFFProvider) {
        if tiffProvider === provider { tiffProvider = nil }
    }
}

/// Converts the clipboard's PNG to TIFF on request.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) { self.png = png }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation else {
            return
        }
        item.setData(tiff, forType: .tiff)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Task { @MainActor in Pasteboard.finished(with: self) }
    }
}
