import AppKit

@MainActor
enum Pasteboard {
    /// Puts the file's PNG on the clipboard, with TIFF for apps that only read TIFF.
    static func copyPNG(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.png, .tiff], owner: nil)
        board.setData(data, forType: .png)
        if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
            board.setData(tiff, forType: .tiff)
        }
    }
}
