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
    private let onEditAll: ([URL]) -> Void
    private let onClaude: (URL) -> Void
    private var panels: [ThumbnailPanel] = []
    /// Every capture shown since the stack was last empty, oldest first, including those whose
    /// thumbnail has already gone: what Edit All opens.
    private var run: [URL] = []
    /// The panel held at the pointer, which `layout` leaves where it is.
    private var atPointer: ThumbnailPanel?
    private var pointerMonitors: [Any] = []
    static let width: CGFloat = 300
    static let margin: CGFloat = 20

    init(
        preferences: Preferences, onEdit: @escaping (URL) -> Void,
        onEditAll: @escaping ([URL]) -> Void, onClaude: @escaping (URL) -> Void
    ) {
        self.preferences = preferences
        self.onEdit = onEdit
        self.onEditAll = onEditAll
        self.onClaude = onClaude
    }

    /// Shows a capture's thumbnail. A recording shows `image`, its first frame, as its poster
    /// and plays a GIF; it stays out of Edit All's run. `note` is a line under the preview.
    func show(url: URL, image: CGImage, isRecording: Bool = false, note: String? = nil) {
        dock()
        let held = preferences.thumbnailAtPointer
        let panel = ThumbnailPanel(
            url: url, image: image, isRecording: isRecording, note: note,
            seconds: preferences.thumbnailSeconds, held: held, onEdit: onEdit, onClaude: onClaude
        ) { [weak self] closing in
            guard let self else { return }
            if closing === atPointer { stopWatchingPointer() }
            panels.removeAll { $0 === closing }
            if panels.isEmpty { run = [] }
            layout()
        }
        panel.onEditAll = { [weak self] in self?.editAll() }
        if !isRecording { run.append(url) }
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

    /// Opens the whole run as a series and clears the stack.
    private func editAll() {
        let captures = run
        for panel in panels { panel.dismiss() }
        onEditAll(captures)
    }

    private func layout(animating moving: ThumbnailPanel? = nil) {
        // On the newest screenshot's thumbnail: a recording's would open other captures.
        let newestScreenshot = panels.first { !$0.isRecording }
        for panel in panels {
            panel.setEditAll(count: panel === newestScreenshot && run.count >= 2 ? run.count : nil)
        }
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
    let isRecording: Bool
    private let onEdit: (URL) -> Void
    private let onClaude: (URL) -> Void
    var onEditAll: () -> Void = {}
    private let claudeButton: NSButton
    private let editAllButton: NSButton
    private let onClose: (ThumbnailPanel) -> Void
    private var timer: Timer?
    private let seconds: Double
    /// Held at the pointer: no delay runs until `release`.
    private var held: Bool

    init(
        url: URL, image: CGImage, isRecording: Bool, note: String?, seconds: Double, held: Bool,
        onEdit: @escaping (URL) -> Void, onClaude: @escaping (URL) -> Void,
        onClose: @escaping (ThumbnailPanel) -> Void
    ) {
        self.held = held
        self.url = url
        self.isRecording = isRecording
        self.onEdit = onEdit
        self.onClaude = onClaude
        claudeButton = FirstMouseButton(title: "For Claude", target: nil, action: nil)
        editAllButton = FirstMouseButton(title: "Edit All", target: nil, action: nil)
        self.onClose = onClose
        self.seconds = seconds
        let width = ThumbnailStack.width
        let imageHeight = min(220, width * CGFloat(image.height) / CGFloat(image.width))
        let barHeight: CGFloat = 44
        let noteHeight: CGFloat = note == nil ? 0 : 20
        let below = barHeight + noteHeight
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: width, height: imageHeight + below),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(
            frame: CGRect(x: 0, y: 0, width: width, height: imageHeight + below))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        // A GIF plays from its file; anything else shows `image`.
        let isGIF = isRecording && url.pathExtension.lowercased() == "gif"
        let shown = (isGIF ? NSImage(contentsOf: url) : nil) ?? NSImage(cgImage: image, size: .zero)
        let preview = DragImageView(url: url, image: shown) { [weak self] in self?.dismiss() }
        preview.animates = isGIF
        preview.frame = CGRect(x: 0, y: below, width: width, height: imageHeight)
        container.addSubview(preview)
        if isRecording && !isGIF {
            let play = NSImageView(
                image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Video")
                    ?? NSImage())
            play.symbolConfiguration = .init(pointSize: 36, weight: .regular)
            play.contentTintColor = .white
            play.shadow = NSShadow()
            play.shadow?.shadowBlurRadius = 4
            play.shadow?.shadowColor = .black.withAlphaComponent(0.6)
            play.frame = CGRect(
                x: (width - 56) / 2, y: (imageHeight - 56) / 2, width: 56, height: 56)
            preview.addSubview(play)
        }

        if let note {
            let label = NSTextField(labelWithString: note)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = note
            label.frame = CGRect(x: 10, y: barHeight, width: width - 20, height: noteHeight - 4)
            container.addSubview(label)
        }

        let bar = NSStackView(frame: CGRect(x: 8, y: 2, width: width - 16, height: barHeight - 4))
        bar.distribution = .fillProportionally
        bar.addArrangedSubview(button("Edit", #selector(editTapped)))
        style(editAllButton, #selector(editAllTapped))
        editAllButton.isHidden = true
        bar.addArrangedSubview(editAllButton)
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

    /// While the capture's export runs, For Claude is disabled and says why; on a recording it
    /// is always disabled.
    func setPreparingForClaude(_ busy: Bool) {
        claudeButton.isEnabled = !busy && !isRecording
        claudeButton.toolTip =
            isRecording
            ? "For Claude reads screenshots, not recordings"
            : busy
                ? "Preparing for Claude…" : "Copy tiles and text Claude can read, as @ references"
    }

    /// At the delay's end the pointer's position decides: over the panel, the delay starts
    /// again; elsewhere, the panel closes. Leaving restarts the delay, but no exit event is
    /// needed to close — one never comes when the stack moves a panel out from under a still
    /// pointer.
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.delayEnded() }
        }
    }

    private func delayEnded() {
        if NSMouseInRect(NSEvent.mouseLocation, frame, false) { startTimer() } else { dismiss() }
    }

    func release() {
        held = false
        startTimer()
    }

    override func mouseExited(with event: NSEvent) { if !held { startTimer() } }

    @objc private func editTapped() {
        onEdit(url)
        dismiss()
    }
    @objc private func editAllTapped() { onEditAll() }
    @objc private func claudeTapped() { onClaude(url) }

    /// Shows Edit All, naming how many captures it opens, or hides it for nil.
    func setEditAll(count: Int?) {
        editAllButton.isHidden = count == nil
        if let count { editAllButton.toolTip = "Edit the last \(count) captures as a series" }
    }
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
