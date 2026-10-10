import AppKit
import ExcerptCore

/// User settings, backed by UserDefaults. Defaults match the workflow excerpt replaces.
final class Preferences {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "libraryFolder": ("~/Documents/Screenshots" as NSString).expandingTildeInPath,
            "namePrefix": "Excerpt",
            "playSound": true,
            "windowBackdrop": true,
            "windowPaddingPoints": 40.0,
            "backdropColor": "E5E5EA",
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
    var thumbnailSeconds: Double { defaults.double(forKey: "thumbnailSeconds") }

    /// Stored as `RRGGBB` hex.
    var backdropColor: RGBA {
        get {
            let hex = UInt32(defaults.string(forKey: "backdropColor")!, radix: 16) ?? 0xE5E5EA
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
