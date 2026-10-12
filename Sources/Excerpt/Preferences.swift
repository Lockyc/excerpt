import ExcerptCapture
import ExcerptCore
import ExcerptEditor
import Foundation

/// User settings, backed by UserDefaults. Defaults match the workflow excerpt replaces.
final class Preferences {
    private static let defaultBackdropHex = "E5E5EA"
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "libraryFolder": ("~/Documents/Screenshots" as NSString).expandingTildeInPath,
            "namePrefix": LibraryNaming.defaultPrefix,
            "playSound": true,
            "windowBackdrop": true,
            "windowPaddingPoints": 40.0,
            "backdropStyle": BackdropStyle.wallpaper.rawValue,
            "backdropColor": Self.defaultBackdropHex,
            "thumbnailSeconds": 15.0,
            "thumbnailAtPointer": false,
        ])
    }

    var libraryFolder: URL {
        get { URL(fileURLWithPath: defaults.string(forKey: "libraryFolder")!) }
        set { defaults.set(newValue.path, forKey: "libraryFolder") }
    }
    var namePrefix: String {
        get { defaults.string(forKey: "namePrefix")! }
        set { defaults.set(newValue, forKey: "namePrefix") }
    }
    var playSound: Bool {
        get { defaults.bool(forKey: "playSound") }
        set { defaults.set(newValue, forKey: "playSound") }
    }
    var windowBackdrop: Bool {
        get { defaults.bool(forKey: "windowBackdrop") }
        set { defaults.set(newValue, forKey: "windowBackdrop") }
    }
    var windowPaddingPoints: Double {
        get { defaults.double(forKey: "windowPaddingPoints") }
        set { defaults.set(newValue, forKey: "windowPaddingPoints") }
    }
    var backdropStyle: BackdropStyle {
        get {
            BackdropStyle(rawValue: defaults.string(forKey: "backdropStyle") ?? "") ?? .wallpaper
        }
        set { defaults.set(newValue.rawValue, forKey: "backdropStyle") }
    }
    /// The editor border's last colour and width; the initial border until one is picked, or
    /// when what is stored can't be read.
    var editorBorder: Border {
        get {
            defaults.data(forKey: "editorBorder").flatMap {
                try? JSONDecoder().decode(Border.self, from: $0)
            } ?? .initial
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "editorBorder") }
    }
    /// The colour, size and text background new annotations get; the initial style until one
    /// is picked, or when what is stored can't be read.
    var editorStyle: AnnotationStyle {
        get {
            defaults.data(forKey: "editorStyle").flatMap {
                try? JSONDecoder().decode(AnnotationStyle.self, from: $0)
            } ?? .initial
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "editorStyle") }
    }
    var thumbnailSeconds: Double { max(1, defaults.double(forKey: "thumbnailSeconds")) }
    var thumbnailAtPointer: Bool {
        get { defaults.bool(forKey: "thumbnailAtPointer") }
        set { defaults.set(newValue, forKey: "thumbnailAtPointer") }
    }

    /// Stored as `RRGGBB` hex; anything but exactly six hex digits (after an optional `#`) reads as the default.
    var backdropColor: RGBA {
        get {
            var text = defaults.string(forKey: "backdropColor") ?? ""
            if text.hasPrefix("#") { text.removeFirst() }
            let fallback = UInt32(Self.defaultBackdropHex, radix: 16)!
            let valid = text.count == 6 && text.allSatisfy(\.isHexDigit)
            let hex = valid ? UInt32(text, radix: 16) ?? fallback : fallback
            return RGBA(
                r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF), a: 255)
        }
        set {
            defaults.set(
                String(format: "%02X%02X%02X", newValue.r, newValue.g, newValue.b),
                forKey: "backdropColor")
        }
    }

    /// The user's hotkeys by action id: `keyCode:modifiers`, or empty for none. An action with no
    /// entry has its default; a value that isn't text is skipped, keeping the others.
    private var hotKeyOverrides: [String: String] {
        defaults.dictionary(forKey: "hotKeys")?.compactMapValues { $0 as? String } ?? [:]
    }

    /// The hotkey for `action`: the user's, else the default; nil when the user cleared it. A
    /// stored value that doesn't parse reads as the default.
    func binding(for action: HotKeyAction) -> HotKeyBinding? {
        guard let stored = hotKeyOverrides[String(action.id)] else { return action.defaultBinding }
        return stored.isEmpty ? nil : HotKeyBinding(stored: stored) ?? action.defaultBinding
    }

    /// Sets `action`'s hotkey; nil clears it.
    func setBinding(_ binding: HotKeyBinding?, for action: HotKeyAction) {
        var overrides = hotKeyOverrides
        overrides[String(action.id)] = binding?.stored ?? ""
        defaults.set(overrides, forKey: "hotKeys")
    }

    /// Returns `action` to its default hotkey.
    func resetBinding(for action: HotKeyAction) {
        var overrides = hotKeyOverrides
        overrides[String(action.id)] = nil
        defaults.set(overrides, forKey: "hotKeys")
    }

    var store: LibraryStore {
        LibraryStore(folder: libraryFolder, naming: LibraryNaming(prefix: namePrefix))
    }
}

/// What fills the padding around a window capture.
enum BackdropStyle: String, CaseIterable {
    /// The desktop picture of the window's display; the colour when it can't be captured.
    case wallpaper
    case colour
}
