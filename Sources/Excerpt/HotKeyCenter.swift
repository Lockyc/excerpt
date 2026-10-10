import Carbon.HIToolbox
import ExcerptCapture
import Foundation

/// System-wide hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission and
/// no dependency. Lives for the process lifetime (the event handler is never removed).
/// Detected conflicts: `.inUse` for a duplicate in this process or another app's exclusive
/// registration; `.system` for an enabled macOS symbolic hotkey (e.g. the built-in screenshot
/// shortcuts), which Carbon registration does not report.
@MainActor
final class HotKeyCenter {
    enum Registration: Equatable {
        case registered
        case inUse
        case system
        case failed(OSStatus)
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var installStatus: OSStatus = noErr
    nonisolated private static let signature: OSType = 0x4558_4350  // 'EXCP'

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                var hotKey = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue()
                let id = hotKey.id
                DispatchQueue.main.async { MainActor.assumeIsolated { center.actions[id]?() } }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(_ binding: HotKeyBinding, id: UInt32, action: @escaping () -> Void)
        -> Registration
    {
        guard installStatus == noErr else { return .failed(installStatus) }
        if systemShortcutHolds(
            keyCode: binding.keyCode, modifiers: binding.modifiers, in: Self.symbolicHotKeys())
        {
            return .system
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &reference)
        switch status {
        case noErr:
            actions[id] = action
            references[id] = reference
            return .registered
        case OSStatus(eventHotKeyExistsErr):
            return .inUse
        default:
            return .failed(status)
        }
    }

    private static func symbolicHotKeys() -> [SymbolicHotKey] {
        var table: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&table) == noErr, let entries = table?.takeRetainedValue() else {
            return []
        }
        return (entries as? [[String: Any]] ?? []).compactMap { entry in
            guard let code = entry["kHISymbolicHotKeyCode"] as? Int,
                let modifiers = entry["kHISymbolicHotKeyModifiers"] as? Int,
                let enabled = entry["kHISymbolicHotKeyEnabled"] as? Bool
            else { return nil }
            return SymbolicHotKey(
                keyCode: UInt32(code), modifiers: UInt32(modifiers), enabled: enabled)
        }
    }
}
