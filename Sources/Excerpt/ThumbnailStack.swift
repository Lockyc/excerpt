import AppKit
import ExcerptCapture

/// Large floating previews in the bottom-left corner, newest at the bottom. Actions are always
/// visible. Each closes after the configured delay (paused while the pointer is over it) or as
/// soon as its file is dragged out. With `thumbnailAtPointer` on, the newest first appears
/// centred on the pointer, with no delay running, and docks in the corner once the pointer
/// leaves `PointerPlacement`'s safety zone around it.
@MainActor
final class ThumbnailStack {
    private let preferences: Preferences
    private let onEdit: (URL) -> Void
    private let onClaude: (URL) -> Void
    private var panels: [ThumbnailPanel] = []
    /// The panel held at the pointer, which `layout` leaves where it is.
    private var atPointer: ThumbnailPanel?
    private var pointerMonitors: [Any] = []
    static let width: CGFloat = 300
    static let margin: CGFloat = 20

    init(
        preferences: Preferences, onEdit: @escaping (URL) -> Void,
        onClaude: @escaping (URL) -> Void
    ) {
        self.preferences = preferences
        self.onEdit = onEdit
        self.onClaude = onClaude
    }

    func show(url: URL, image: CGImage) {
        dock()
        let held = preferences.thumbnailAtPointer
        let panel = ThumbnailPanel(
            url: url, image: image, seconds: preferences.thumbnailSeconds, held: held,
            onEdit: onEdit, onClaude: onClaude
        ) { [weak self] closing in
            guard let self else { return }
            if closing === atPointer { stopWatchingPointer() }
            panels.removeAll { $0 === closing }
            layout()
        }
        panels.insert(panel, at: 0)
        if panels.count > 4 { panels.last?.dismiss() }
        if held { holdAtPointer(panel) }
        layout()
        panel.orderFrontRegardless()
    }

    private func holdAtPointer(_ panel: ThumbnailPanel) {
        let pointer = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(
            PointerPlacement.frame(size: panel.frame.size, centredOn: pointer, within: visible),
            display: false)
        atPointer = panel
        let check: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        pointerMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: check),
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                check(event)
                return event
            },
        ].compactMap { $0 }
    }

    private func pointerMoved() {
        guard let panel = atPointer,
            !PointerPlacement.isInSafetyZone(NSEvent.mouseLocation, around: panel.frame)
        else { return }
        dock()
    }

    /// Sends the panel held at the pointer to its corner slot and starts its delay.
    private func dock() {
        guard let panel = atPointer else { return }
        stopWatchingPointer()
        layout(animating: panel)
        panel.release()
    }

    private func stopWatchingPointer() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors = []
        atPointer = nil
    }

    /// Shows For Claude as busy on the thumbnails whose capture `isCapture` picks while its
    /// export runs.
    func setPreparingForClaude(_ busy: Bool, isCapture: (URL) -> Bool) {
        for panel in panels where isCapture(panel.url) {
            panel.setPreparingForClaude(busy)
        }
    }

    private func layout(animating moving: ThumbnailPanel? = nil) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.minY + Self.margin
        for panel in panels where panel !== atPointer {
            let origin = CGPoint(x: screen.minX + Self.margin, y: y)
            if panel === moving {
                panel.animator().setFrame(
                    CGRect(origin: origin, size: panel.frame.size), display: true)
            } else {
                panel.setFrameOrigin(origin)
            }
            y += panel.frame.height + 10
        }
    }
}

@MainActor
final class ThumbnailPanel: NSPanel {
    let url: URL
    private let onEdit: (URL) -> Void
    private let onClaude: (URL) -> Void
    private let claudeButton: NSButton
    private let onClose: (ThumbnailPanel) -> Void
    private var timer: Timer?
    private let seconds: Double
    /// Held at the pointer: no delay runs until `release`.
    private var held: Bool

    init(
        url: URL, image: CGImage, seconds: Double, held: Bool, onEdit: @escaping (URL) -> Void,
        onClaude: @escaping (URL) -> Void, onClose: @escaping (ThumbnailPanel) -> Void
    ) {
        self.held = held
        self.url = url
        self.onEdit = onEdit
        self.onClaude = onClaude
        claudeButton = FirstMouseButton(title: "For Claude", target: nil, action: nil)
        self.onClose = onClose
        self.seconds = seconds
        let width = ThumbnailStack.width
        let imageHeight = min(220, width * CGFloat(image.height) / CGFloat(image.width))
        let barHeight: CGFloat = 44
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: width, height: imageHeight + barHeight),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(
            frame: CGRect(x: 0, y: 0, width: width, height: imageHeight + barHeight))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let preview = DragImageView(url: url, image: NSImage(cgImage: image, size: .zero)) {
            [weak self] in
            self?.dismiss()
        }
        preview.frame = CGRect(x: 0, y: barHeight, width: width, height: imageHeight)
        container.addSubview(preview)

        let bar = NSStackView(frame: CGRect(x: 8, y: 2, width: width - 16, height: barHeight - 4))
        bar.distribution = .fillEqually
        bar.addArrangedSubview(button("Edit", #selector(editTapped)))
        style(claudeButton, #selector(claudeTapped))
        setPreparingForClaude(false)
        bar.addArrangedSubview(claudeButton)
        bar.addArrangedSubview(button("Close", #selector(closeTapped)))
        container.addSubview(bar)
        contentView = container

        container.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        if !held { startTimer() }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = FirstMouseButton(title: title, target: nil, action: nil)
        style(b, action)
        return b
    }

    private func style(_ b: NSButton, _ action: Selector) {
        b.target = self
        b.action = action
        b.bezelStyle = .recessed
        b.controlSize = .large
    }

    /// While the capture's export runs, For Claude is disabled and says why.
    func setPreparingForClaude(_ busy: Bool) {
        claudeButton.isEnabled = !busy
        claudeButton.toolTip =
            busy ? "Preparing for Claude…" : "Copy tiles and text Claude can read, as @ references"
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func release() {
        held = false
        startTimer()
    }

    override func mouseEntered(with event: NSEvent) { timer?.invalidate() }
    override func mouseExited(with event: NSEvent) { if !held { startTimer() } }

    @objc private func editTapped() {
        onEdit(url)
        dismiss()
    }
    @objc private func claudeTapped() { onClaude(url) }
    @objc private func closeTapped() { dismiss() }

    func dismiss() {
        timer?.invalidate()
        orderOut(nil)
        onClose(self)
    }
}

/// The preview image; dragging it hands the file to the drop target.
@MainActor
final class DragImageView: NSImageView, NSDraggingSource {
    private let url: URL
    private let onDragged: () -> Void

    init(url: URL, image: NSImage, onDragged: @escaping () -> Void) {
        self.url = url
        self.onDragged = onDragged
        super.init(frame: .zero)
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}  // keep NSImageView from eating the drag

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    )
        -> NSDragOperation
    {
        [.copy]
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        if operation != [] { onDragged() }
    }
}
