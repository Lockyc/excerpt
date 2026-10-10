import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission and
/// no dependency. A combination another app already holds reports `.inUse`.
@MainActor
final class HotKeyCenter {
    enum Registration: Equatable {
        case registered
        case inUse
        case failed(OSStatus)
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private static let signature: OSType = 0x4558_4350  // 'EXCP'

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
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
}
