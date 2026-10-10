import AppKit

/// Large floating previews in the bottom-left corner, newest at the bottom. Actions are always
/// visible. Each closes after the configured delay (paused while the pointer is over it) or as
/// soon as its file is dragged out.
@MainActor
final class ThumbnailStack {
    private let preferences: Preferences
    private var panels: [ThumbnailPanel] = []
    static let width: CGFloat = 300
    static let margin: CGFloat = 20

    init(preferences: Preferences) { self.preferences = preferences }

    func show(url: URL, image: CGImage) {
        let panel = ThumbnailPanel(url: url, image: image, seconds: preferences.thumbnailSeconds) {
            [weak self] closing in
            self?.panels.removeAll { $0 === closing }
            self?.layout()
        }
        panels.insert(panel, at: 0)
        if panels.count > 4 { panels.last?.dismiss() }
        layout()
        panel.orderFrontRegardless()
    }

    private func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.minY + Self.margin
        for panel in panels {
            panel.setFrameOrigin(CGPoint(x: screen.minX + Self.margin, y: y))
            y += panel.frame.height + 10
        }
    }
}

@MainActor
final class ThumbnailPanel: NSPanel {
    private let url: URL
    private let onClose: (ThumbnailPanel) -> Void
    private var timer: Timer?
    private let seconds: Double

    init(url: URL, image: CGImage, seconds: Double, onClose: @escaping (ThumbnailPanel) -> Void) {
        self.url = url
        self.onClose = onClose
        self.seconds = seconds
        let width = ThumbnailStack.width
        let imageHeight = min(220, width * CGFloat(image.height) / CGFloat(image.width))
        let barHeight: CGFloat = 32
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
        bar.addArrangedSubview(button("Copy", #selector(copyImage)))
        let edit = button("Edit", nil)
        edit.isEnabled = false
        edit.toolTip = "The editor isn't in this build yet"
        bar.addArrangedSubview(edit)
        let claude = button("For Claude", nil)
        claude.isEnabled = false
        claude.toolTip = "The Claude export isn't in this build yet"
        bar.addArrangedSubview(claude)
        bar.addArrangedSubview(button("Close", #selector(closeTapped)))
        container.addSubview(bar)
        contentView = container

        container.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        startTimer()
    }

    private func button(_ title: String, _ action: Selector?) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .recessed
        b.controlSize = .small
        return b
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    override func mouseEntered(with event: NSEvent) { timer?.invalidate() }
    override func mouseExited(with event: NSEvent) { startTimer() }

    @objc private func copyImage() { Pasteboard.copyPNG(at: url) }
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
