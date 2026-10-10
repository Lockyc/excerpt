import Carbon.HIToolbox
import ExcerptCapture
import Foundation

/// System-wide hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission and
/// no dependency. Lives for the process lifetime (the event handler is never removed).
/// Conflicts: `.inUse` for a duplicate in this process or another app's exclusive registration
/// (not registered); `.system` for an enabled macOS symbolic hotkey (e.g. the built-in
/// screenshot shortcuts), which Carbon registration does not report. A `.system` hotkey is
/// registered and fires as soon as the macOS shortcut is turned off, so `status(id:)` reads the
/// symbolic hotkeys live.
@MainActor
final class HotKeyCenter {
    enum Registration: Equatable {
        case registered
        case inUse
        /// Registered, but an enabled macOS shortcut currently holds the same keys.
        case system
        case failed(OSStatus)
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var bindings: [UInt32: HotKeyBinding] = [:]
    private var failures: [UInt32: Registration] = [:]
    /// Every hotkey's state as `suspend` found it; reported in place of the live state until
    /// `resume`.
    private var suspended: [UInt32: Registration]?
    private var installStatus: OSStatus = noErr
    nonisolated private static let signature: OSType = 0x4558_4350  // 'EXCP'

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                var hotKey = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                guard status == noErr, hotKey.signature == HotKeyCenter.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue()
                let id = hotKey.id
                DispatchQueue.main.async { MainActor.assumeIsolated { center.actions[id]?() } }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(_ binding: HotKeyBinding, id: UInt32, action: @escaping () -> Void) {
        bindings[id] = binding
        guard installStatus == noErr else {
            failures[id] = .failed(installStatus)
            return
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &reference)
        switch status {
        case noErr:
            actions[id] = action
            references[id] = reference
        case OSStatus(eventHotKeyExistsErr):
            failures[id] = .inUse
        default:
            failures[id] = .failed(status)
        }
    }

    /// Removes hotkey `id` and everything known about it; nothing when it has none. Carbon fails
    /// an unregister only for a reference it never issued, which this centre never holds.
    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) {
            _ = UnregisterEventHotKey(reference)
        }
        actions[id] = nil
        bindings[id] = nil
        failures[id] = nil
    }

    /// Unregisters every hotkey, so a key press reaches the app instead, while `status(id:)`
    /// goes on reporting the states they had until `resume`.
    func suspend() {
        guard suspended == nil else { return }
        let ids = Array(bindings.keys)
        suspended = Dictionary(uniqueKeysWithValues: ids.map { ($0, status(id: $0)) })
        for id in ids { unregister(id: id) }
    }

    /// Ends a suspension: `status(id:)` reports live states again. Registering is the caller's.
    func resume() { suspended = nil }

    /// The hotkey's state now: its registration outcome, or `.system` while a macOS shortcut
    /// holds the same keys. While suspended, the state it had when suspended.
    func status(id: UInt32) -> Registration {
        if let suspended { return suspended[id] ?? .registered }
        if let failure = failures[id] { return failure }
        guard let binding = bindings[id] else { return .registered }
        return systemShortcutHolds(
            keyCode: binding.keyCode, modifiers: binding.modifiers, in: Self.symbolicHotKeys())
            ? .system : .registered
    }

    /// macOS's symbolic hotkey table now.
    static func symbolicHotKeys() -> [SymbolicHotKey] {
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
