import AppKit
import ExcerptCapture

/// The all-in-one selector: a menu of every capture mode at the pointer, each with its own
/// hotkey shown. The arrow keys, or a mode's first letter, then Return, pick one; Esc or a click
/// outside picks none.
@MainActor
final class CaptureSelector: NSObject {
    private var chosen: HotKeyAction?

    /// The mode picked, or nil; `binding` gives each mode's hotkey to show beside it.
    func choose(binding: (HotKeyAction) -> HotKeyBinding?) -> HotKeyAction? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Capture"))
        for mode in HotKeyAction.modes {
            let item = NSMenuItem(
                title: mode.modeName, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(mode.id)
            binding(mode)?.show(on: item)
            menu.addItem(item)
        }
        chosen = nil
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return chosen
    }

    @objc private func pick(_ sender: NSMenuItem) {
        chosen = HotKeyAction(rawValue: UInt32(sender.tag))
    }
}
