import AppKit

@MainActor
enum Pasteboard {
    struct WriteFailed: Error, LocalizedError {
        var errorDescription: String? { "the pasteboard refused it" }
    }

    /// Puts the file's PNG on the clipboard, with TIFF for apps that only read TIFF.
    static func copyPNG(at url: URL) throws {
        try copyPNGs([Data(contentsOf: url)])
    }

    /// Puts plain text on the clipboard.
    static func copyText(_ text: String) throws {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw WriteFailed() }
    }

    /// The providers of the TIFFs on the clipboard now, held until the pasteboard is done with
    /// each.
    private static var tiffProviders: [TIFFProvider] = []

    /// Puts PNG images on the clipboard, one item each in order, with TIFF for apps that only
    /// read TIFF. The TIFF is made only when such an app asks for it: converting a full-screen
    /// capture costs over 100ms.
    static func copyPNGs(_ images: [Data]) throws {
        let board = NSPasteboard.general
        board.clearContents()
        var items: [NSPasteboardItem] = []
        var providers: [TIFFProvider] = []
        for data in images {
            let item = NSPasteboardItem()
            let provider = TIFFProvider(png: data)
            guard item.setData(data, forType: .png),
                item.setDataProvider(provider, forTypes: [.tiff])
            else { throw WriteFailed() }
            items.append(item)
            providers.append(provider)
        }
        guard board.writeObjects(items) else { throw WriteFailed() }
        tiffProviders = providers
    }

    fileprivate static func finished(with provider: TIFFProvider) {
        tiffProviders.removeAll { $0 === provider }
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
