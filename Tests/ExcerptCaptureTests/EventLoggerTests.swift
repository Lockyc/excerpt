import CoreGraphics
import ExcerptCore
import Testing

@testable import ExcerptCapture

@Suite struct EventLoggerTests {
    // A 1440×900pt Retina display at the origin; the region is 400×600pt of it.
    let region = ScrollRegion(
        displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2,
        pixelRect: CGRect(x: 200, y: 100, width: 800, height: 1200), primaryHeight: 900)

    @Test func masterPointIsTopLeftPixels() {
        let frame = region.appKitFrame
        let point = EventLogger.masterPoint(
            forAppKit: CGPoint(x: frame.minX + 1, y: frame.minY + 1), region: region)
        #expect(point == CGPoint(x: 2, y: region.pixelRect.height - 2))
    }

    @Test func pointOutsideRegionIsNil() {
        let frame = region.appKitFrame
        #expect(
            EventLogger.masterPoint(
                forAppKit: CGPoint(x: frame.minX - 1, y: frame.midY), region: region) == nil)
        #expect(
            EventLogger.masterPoint(
                forAppKit: CGPoint(x: frame.midX, y: frame.maxY + 1), region: region) == nil)
    }

    @Test func otherAppsShortcutsDroppedForAWindowRecording() {
        #expect(
            !EventLogger.accepts(
                keyCode: 8, modifiers: .command, frontmost: 200, recorded: 100, ownHotKeys: []))
        #expect(
            EventLogger.accepts(
                keyCode: 8, modifiers: .command, frontmost: 100, recorded: 100, ownHotKeys: []))
        #expect(
            EventLogger.accepts(
                keyCode: 8, modifiers: .command, frontmost: 200, recorded: nil, ownHotKeys: []))
    }

    @Test func ownHotKeyIsNeverLogged() {
        let own = HotKeyBinding(keyCode: 26, modifiers: HotKeyBinding.commandShift)
        #expect(
            !EventLogger.accepts(
                keyCode: 26, modifiers: [.command, .shift], frontmost: nil, recorded: nil,
                ownHotKeys: [own]))
        #expect(
            EventLogger.accepts(
                keyCode: 26, modifiers: [.command], frontmost: nil, recorded: nil,
                ownHotKeys: [own]))
    }

    @Test func capsLockAndFnNeverReachTheModifiers() {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlphaShift, .maskSecondaryFn]
        let modifiers = EventLogger.modifiers(of: flags)
        #expect(modifiers == [.command, .shift])
        let own = HotKeyBinding(keyCode: 26, modifiers: HotKeyBinding.commandShift)
        #expect(
            !EventLogger.accepts(
                keyCode: 26, modifiers: modifiers, frontmost: nil, recorded: nil,
                ownHotKeys: [own]))
    }

    @MainActor @Test func deniedLogsClicksOnly() {
        let logger = EventLogger(
            region: region, frontmostPID: nil, ownHotKeys: [], clock: { 0 },
            hasInputMonitoring: false)
        let log = logger.stop()
        #expect(!log.shortcutsLogged)
        #expect(log.scale == 2)
        #expect(log.version == RecordingEventLog.version)
    }

    /// Permission granted, but the key tap can't be made: the log mustn't claim shortcuts.
    @MainActor @Test func aKeyTapThatFailsToStartLogsClicksOnly() {
        let logger = EventLogger(
            region: region, frontmostPID: nil, ownHotKeys: [], clock: { 0 },
            hasInputMonitoring: true, createKeyTap: { _, _ in nil })
        logger.start()
        #expect(!logger.shortcutsLogged)
        #expect(!logger.stop().shortcutsLogged)
    }
}
