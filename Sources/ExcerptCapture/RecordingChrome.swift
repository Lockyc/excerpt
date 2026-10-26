import AppKit

/// What surrounds a recording on screen: the 3-2-1 countdown, a thin outline just outside the
/// area, and the control bar (elapsed time, Pause/Resume, Stop, Discard) placed outside the area
/// by `ControlBarPlacement`. The stream leaves out Excerpt's windows, so none of it is recorded.
/// `area` is in AppKit points.
@MainActor
public final class RecordingChrome {
    public var onPause: () -> Void = {}
    public var onResume: () -> Void = {}
    public var onStop: () -> Void = {}
    public var onDiscard: () -> Void = {}

    private let area: CGRect
    private let outline: NSWindow
    private let bar: ChromePanel
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let actions = ChromeActions()
    private var pauseButton: NSButton?
    private var paused = false
    private var countdownPanel: ChromePanel?
    private var closed = false
    private var escaped = false

    public init(area: CGRect) {
        self.area = area
        outline = Self.makeOutline(area: area)
        bar = ChromePanel(frame: .zero)
        buildBar()
        actions.pauseToggled = { [weak self] in self?.togglePause() }
        actions.stopped = { [weak self] in self?.onStop() }
        actions.discarded = { [weak self] in self?.onDiscard() }
        bar.onEscape = { [weak self] in self?.onDiscard() }
    }

    /// Shows 3, 2, 1 for a second each, centred in the area, and returns true once the last
    /// has gone. Returns false when Esc is pressed or `close()` is called meanwhile.
    public func countdown() async -> Bool {
        guard !closed else { return false }
        let size: CGFloat = 140
        let panel = ChromePanel(
            frame: CGRect(
                x: area.midX - size / 2, y: area.midY - size / 2, width: size, height: size))
        panel.onEscape = { [weak self] in self?.escaped = true }
        let numeral = NSTextField(labelWithString: "3")
        numeral.font = .monospacedDigitSystemFont(ofSize: 80, weight: .semibold)
        numeral.alignment = .center
        numeral.frame = CGRect(x: 0, y: (size - 96) / 2, width: size, height: 96)
        panel.contentView?.addSubview(numeral)
        countdownPanel = panel
        // Esc reaches only the key window, and a key window needs the app active.
        // The app being demonstrated gets focus back afterwards, whatever the outcome.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.orderOut(nil)
            countdownPanel = nil
            if let previous, previous != NSRunningApplication.current {
                previous.activate()
            }
        }
        for digit in (1...3).reversed() {
            numeral.stringValue = String(digit)
            let end = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < end {
                if closed || escaped { return false }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
            }
        }
        return !(closed || escaped)
    }

    /// Shows the outline and the control bar.
    public func showRecording() {
        guard !closed else { return }
        countdownPanel?.orderOut(nil)
        outline.orderFrontRegardless()
        let screens = NSScreen.screens
        let own = Self.screen(containing: area, in: screens)
        let frame = ControlBarPlacement.frame(
            bar: bar.frame.size, area: area,
            screen: (own ?? NSScreen.main)?.visibleFrame ?? area,
            otherScreens: screens.filter { $0 !== own }.map(\.visibleFrame))
        bar.setFrame(frame, display: true)
        bar.orderFrontRegardless()
    }

    /// `remaining` is passed only over the last 30 s of the recording.
    public func update(recorded: Double, remaining: Double?) {
        timeLabel.stringValue = Self.timeText(recorded: recorded, remaining: remaining)
    }

    public func close() {
        closed = true
        onPause = {}
        onResume = {}
        onStop = {}
        onDiscard = {}
        countdownPanel?.orderOut(nil)
        outline.orderOut(nil)
        bar.orderOut(nil)
    }

    /// `0:42`, or `0:42 · 0:18 left` once `remaining` is given.
    static func timeText(recorded: Double, remaining: Double?) -> String {
        func clock(_ seconds: Int) -> String {
            String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        let elapsed = clock(max(0, Int(recorded)))
        guard let remaining else { return elapsed }
        return "\(elapsed) · \(clock(max(0, Int(remaining.rounded(.up))))) left"
    }

    /// The screen holding most of `area`, by AppKit frame.
    static func screen(containing area: CGRect, in screens: [NSScreen]) -> NSScreen? {
        screens.max { lhs, rhs in
            lhs.frame.intersection(area).area < rhs.frame.intersection(area).area
        }
    }

    private func togglePause() {
        paused.toggle()
        pauseButton?.title = paused ? "Resume" : "Pause"
        paused ? onPause() : onResume()
    }

    private static func makeOutline(area: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: area.insetBy(dx: -1, dy: -1), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.systemRed.cgColor
        window.contentView = view
        return window
    }

    private func buildBar() {
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        // Wide enough for the longest reading, so the bar never resizes or truncates.
        let widest = Self.timeText(recorded: 299, remaining: 29.5)
        let width = NSAttributedString(
            string: widest, attributes: [.font: timeLabel.font as Any]
        ).size().width
        timeLabel.widthAnchor.constraint(equalToConstant: ceil(width) + 6).isActive = true
        let pause = FirstMouseButton(
            title: "Pause", target: actions, action: #selector(ChromeActions.togglePause))
        let stop = FirstMouseButton(
            title: "Stop", target: actions, action: #selector(ChromeActions.stop))
        let discard = FirstMouseButton(
            title: "Discard", target: actions, action: #selector(ChromeActions.discard))
        pauseButton = pause
        for button in [pause, stop, discard] { button.controlSize = .small }
        let row = NSStackView(views: [timeLabel, pause, stop, discard])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        guard let content = bar.contentView else { return }
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        bar.setContentSize(row.fittingSize)
        bar.isMovableByWindowBackground = true
    }
}

extension CGRect {
    fileprivate var area: CGFloat { isNull ? 0 : width * height }
}

/// The buttons' target: an NSObject the panel can message.
@MainActor
private final class ChromeActions: NSObject {
    var pauseToggled: () -> Void = {}
    var stopped: () -> Void = {}
    var discarded: () -> Void = {}

    @objc func togglePause() { pauseToggled() }
    @objc func stop() { stopped() }
    @objc func discard() { discarded() }
}

/// A non-activating borderless HUD panel that can still be key, so Esc reaches `onEscape`.
private final class ChromePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 53, isKeyWindow { onEscape?() } else { super.keyDown(with: event) }
    }

    init(frame: CGRect) {
        super.init(
            contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
            defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        contentView = background
    }
}
