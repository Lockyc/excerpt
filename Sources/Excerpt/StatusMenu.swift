import AppKit
import QuickLookThumbnailing
import Sparkle

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let updater: SPUStandardUpdaterController?
    private let perform: (HotKeyAction) -> Void
    private let recentCaptures: () throws -> [URL]
    private let openCapture: (URL) -> Void
    private let chooseCapture: () -> Void
    private let openLibrary: () -> Void
    private let openSettings: () -> Void
    private let hotKeyStates: () -> [HotKeyAction: HotKeyState]

    /// How many captures Recent Captures lists.
    static let recentLimit = 10
    /// The thumbnail box each recent capture shows in, so titles line up whatever its shape.
    static let thumbnailSize = NSSize(width: 96, height: 64)

    init(
        perform: @escaping (HotKeyAction) -> Void,
        recentCaptures: @escaping () throws -> [URL], openCapture: @escaping (URL) -> Void,
        chooseCapture: @escaping () -> Void, openLibrary: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        hotKeyStates: @escaping () -> [HotKeyAction: HotKeyState],
        updater: SPUStandardUpdaterController?
    ) {
        self.updater = updater
        self.perform = perform
        self.recentCaptures = recentCaptures
        self.openCapture = openCapture
        self.chooseCapture = chooseCapture
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.hotKeyStates = hotKeyStates
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: "scissors", accessibilityDescription: "Excerpt")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        rebuild(menu)
    }

    /// Hotkeys and their notes reflect the state at the moment the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let states = hotKeyStates()
        for action in HotKeyAction.allCases {
            let entry = NSMenuItem(
                title: action.title, action: #selector(capture(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = Int(action.id)
            menu.addItem(entry)
            guard let state = states[action] else { continue }
            state.binding.show(on: entry)
            if let text = state.note {
                let note = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.indentationLevel = 1
                menu.addItem(note)
            }
        }
        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu()
        menu.addItem(recent)
        menu.addItem(
            withTitle: "Open Library Folder", action: #selector(library), keyEquivalent: ""
        ).target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",")
            .target = self
        // Shown without an updater too (`swift run`), just inert, so the menu reads the same.
        menu.addItem(
            withTitle: "Check for Updates…",
            action: updater.map { _ in #selector(SPUStandardUpdaterController.checkForUpdates(_:))
            },
            keyEquivalent: ""
        ).target = updater
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Excerpt", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
    }

    /// The newest captures, each opening in the editor, then Open Capture… for any other.
    private func recentMenu() -> NSMenu {
        let menu = NSMenu()
        do {
            let captures = try recentCaptures()
            if captures.isEmpty { menu.addItem(note("No captures yet")) }
            for url in captures {
                let entry = NSMenuItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    action: #selector(open(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = url
                entry.toolTip = url.path
                entry.image = NSImage(size: Self.thumbnailSize)
                loadThumbnail(url, into: entry)
                menu.addItem(entry)
            }
        } catch {
            menu.addItem(note("The library folder can't be read"))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Capture…", action: #selector(choose), keyEquivalent: "")
            .target = self
        return menu
    }

    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Fills in the entry's thumbnail once Quick Look has one; the entry shows an empty box
    /// of the same size until then.
    private func loadThumbnail(_ url: URL, into entry: NSMenuItem) {
        let size = Self.thumbnailSize
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            DispatchQueue.main.async {
                let fitted = Self.fit(cgImage, in: size)
                MainActor.assumeIsolated { entry.image = fitted }
            }
        }
    }

    /// The image scaled to fit, centred in a box of `size`.
    nonisolated private static func fit(_ cgImage: CGImage, in size: NSSize) -> NSImage {
        let scale = min(
            size.width / CGFloat(cgImage.width), size.height / CGFloat(cgImage.height))
        let drawn = NSSize(
            width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        let source = NSImage(cgImage: cgImage, size: drawn)
        return NSImage(size: size, flipped: false) { _ in
            source.draw(
                in: NSRect(
                    x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                    width: drawn.width, height: drawn.height))
            return true
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openCapture(url) }
    }
    @objc private func choose() { chooseCapture() }
    @objc private func capture(_ sender: NSMenuItem) {
        if let action = HotKeyAction(rawValue: UInt32(sender.tag)) { perform(action) }
    }
    @objc private func library() { openLibrary() }
    @objc private func settings() { openSettings() }
}
