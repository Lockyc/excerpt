import ExcerptCore
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
            "backdropColor": Self.defaultBackdropHex,
            "thumbnailSeconds": 15.0,
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
    var thumbnailSeconds: Double { max(1, defaults.double(forKey: "thumbnailSeconds")) }

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

    var store: LibraryStore {
        LibraryStore(folder: libraryFolder, naming: LibraryNaming(prefix: namePrefix))
    }
}
