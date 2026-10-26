import AppKit
import ExcerptCore

/// Logs the shortcuts pressed and the clicks made inside a recording's region, stamped with
/// recorded time. Shortcuts need Input Monitoring (a listen-only key tap); without it only
/// clicks are logged and the log says so.
@MainActor public final class EventLogger {
    private let region: ScrollRegion
    private let frontmostPID: pid_t?
    private let ownHotKeys: [HotKeyBinding]
    private let clock: () -> Double?
    private let hasInputMonitoring: Bool
    private let createKeyTap: KeyTapFactory
    /// Whether shortcuts are being logged: Input Monitoring was granted and the key tap started.
    /// False until `start`.
    public private(set) var shortcutsLogged = false
    private var events: [RecordingEvent] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitor: Any?

    /// Makes the listen-only key tap for a callback and its userInfo; nil when it can't.
    typealias KeyTapFactory = (CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?

    /// `frontmostPID` is the recorded app for a window recording, nil otherwise. `clock`
    /// returns recorded seconds, or nil while paused. `hasInputMonitoring` is the permission
    /// at the moment the recording starts.
    public convenience init(
        region: ScrollRegion, frontmostPID: pid_t?, ownHotKeys: [HotKeyBinding],
        clock: @escaping () -> Double?,
        hasInputMonitoring: Bool = InputMonitoring.hasPermission()
    ) {
        self.init(
            region: region, frontmostPID: frontmostPID, ownHotKeys: ownHotKeys, clock: clock,
            hasInputMonitoring: hasInputMonitoring, createKeyTap: Self.sessionKeyTap)
    }

    init(
        region: ScrollRegion, frontmostPID: pid_t?, ownHotKeys: [HotKeyBinding],
        clock: @escaping () -> Double?, hasInputMonitoring: Bool,
        createKeyTap: @escaping KeyTapFactory
    ) {
        self.region = region
        self.frontmostPID = frontmostPID
        self.ownHotKeys = ownHotKeys
        self.clock = clock
        self.hasInputMonitoring = hasInputMonitoring
        self.createKeyTap = createKeyTap
    }

    /// A key-down tap on the login session, listening only.
    private static func sessionKeyTap(
        callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer
    ) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback, userInfo: userInfo)
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

    /// The four modifiers a logged shortcut can carry; Caps Lock, Fn and the rest are ignored.
    public nonisolated static func modifiers(of flags: CGEventFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// Begins listening; a second call while listening does nothing.
    public func start() {
        guard monitor == nil, tap == nil else { return }
        if hasInputMonitoring { startKeyTap() }
        shortcutsLogged = tap != nil
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            // For a global monitor `locationInWindow` is the screen point.
            let point = event.locationInWindow
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
        if let tap {
            CFMachPortInvalidate(tap)
            // Balances the retain `startKeyTap` gave the tap's userInfo.
            Unmanaged.passUnretained(self).release()
        }
        tap = nil
        tapSource = nil
        return RecordingEventLog(
            version: RecordingEventLog.version, scale: Double(region.scale),
            shortcutsLogged: shortcutsLogged,
            events: events)
    }

    private func startKeyTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let logger = Unmanaged<EventLogger>.fromOpaque(userInfo).takeUnretainedValue()
            MainActor.assumeIsolated { logger.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }
        // Retained for the tap's lifetime, so a logger released without `stop()` leaks rather
        // than leaving the callback a dangling pointer.
        let userInfo = Unmanaged.passRetained(self)
        guard let tap = createKeyTap(callback, userInfo.toOpaque()) else {
            userInfo.release()
            return
        }
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
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let time = clock()
        else { return }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifiers(of: event.flags)
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
