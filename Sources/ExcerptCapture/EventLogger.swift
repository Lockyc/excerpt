import AppKit
import ExcerptCore

/// Logs the shortcuts pressed and the clicks made inside a recording's region, stamped with
/// recorded time. Shortcuts need Input Monitoring (a listen-only key tap); without it only
/// clicks are logged and the log says so.
@MainActor public final class EventLogger {
    private let region: ScrollRegion
    private let scale: Double
    private let frontmostPID: pid_t?
    private let ownHotKeys: [HotKeyBinding]
    private let clock: () -> Double?
    private let shortcutsLogged: Bool
    private var events: [RecordingEvent] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitor: Any?

    /// `frontmostPID` is the recorded app for a window recording, nil otherwise. `clock`
    /// returns recorded seconds, or nil while paused. `hasInputMonitoring` is the permission
    /// at the moment the recording starts.
    public init(
        region: ScrollRegion, scale: Double, frontmostPID: pid_t?, ownHotKeys: [HotKeyBinding],
        clock: @escaping () -> Double?,
        hasInputMonitoring: Bool = InputMonitoring.hasPermission()
    ) {
        self.region = region
        self.scale = scale
        self.frontmostPID = frontmostPID
        self.ownHotKeys = ownHotKeys
        self.clock = clock
        shortcutsLogged = hasInputMonitoring
    }

    /// Where an AppKit global point lands in master pixels, top-left origin; nil outside the
    /// region.
    public nonisolated static func masterPoint(forAppKit point: CGPoint, region: ScrollRegion)
        -> CGPoint?
    {
        let frame = region.appKitFrame
        guard frame.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - frame.minX) * region.scale, y: (frame.maxY - point.y) * region.scale)
    }

    /// Whether a key press is logged: not another app's while a window is recorded, and never
    /// one of the app's own hotkeys.
    public nonisolated static func accepts(
        keyCode: UInt16, modifiers: KeyModifiers, frontmost: pid_t?, recorded: pid_t?,
        ownHotKeys: [HotKeyBinding]
    ) -> Bool {
        if let recorded, frontmost != recorded { return false }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return !ownHotKeys.contains(HotKeyBinding(keyCode: keyCode, flags: flags))
    }

    /// Begins listening; a second call while listening does nothing.
    public func start() {
        guard monitor == nil, tap == nil else { return }
        if shortcutsLogged { startKeyTap() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            let button: ClickButton = event.type == .rightMouseDown ? .right : .left
            MainActor.assumeIsolated { self?.logClick(at: point, button: button) }
        }
    }

    /// Stops listening and returns everything logged.
    public func stop() -> RecordingEventLog {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        return RecordingEventLog(
            version: RecordingEventLog.version, scale: scale, shortcutsLogged: shortcutsLogged,
            events: events)
    }

    private func startKeyTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let logger = Unmanaged<EventLogger>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { logger.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            logKey(event)
        default:
            break
        }
    }

    private func logKey(_ event: CGEvent) {
        guard let time = clock() else { return }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        var modifiers: KeyModifiers = []
        if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
        if event.flags.contains(.maskControl) { modifiers.insert(.control) }
        if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
        guard
            Self.accepts(
                keyCode: keyCode, modifiers: modifiers,
                frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                recorded: frontmostPID, ownHotKeys: ownHotKeys),
            let label = ShortcutFilter.label(
                keyCode: keyCode, modifiers: modifiers,
                character: NSEvent(cgEvent: event)?.charactersIgnoringModifiers)
        else { return }
        events.append(.shortcut(time: time, label: label))
    }

    private func logClick(at point: CGPoint, button: ClickButton) {
        guard let time = clock(), let master = Self.masterPoint(forAppKit: point, region: region)
        else { return }
        events.append(.click(time: time, x: Double(master.x), y: Double(master.y), button: button))
    }
}
