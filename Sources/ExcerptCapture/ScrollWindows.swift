import AppKit
import ExcerptCore

/// The HUD and the live preview of a scrolling capture. The HUD's Done and Cancel buttons carry
/// Return and Esc and also work by click, even while another app is frontmost, so ending the
/// capture never depends on where keyboard focus went. Its mark says how the capture is going:
/// a spinner while it runs, a warning when something needs the user, a check at the page's end.
/// A capture that couldn't start or ended early says why in the same HUD, with one OK.
@MainActor
public final class ScrollWindows {
    private let hud: NSPanel
    private let preview: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let mark = NSImageView()
    private let accessibilityButton: NSButton
    private let cancelButton: NSButton
    private let doneButton: NSButton
    private let imageView = NSImageView()
    private let heightLabel = NSTextField(labelWithString: "")
    private let actions: Actions
    private var shownHeight = -1
    private var activeObserver: NSObjectProtocol?

    /// `region`, `hud` (the HUD's frame, from `ScrollChromeLayout.hud` at its `hudSize`) and
    /// `visible` (its screen's visible frame) in AppKit points.
    public init(
        region: CGRect, hud hudFrame: CGRect, visible: CGRect, onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void, onOpenAccessibility: @escaping () -> Void
    ) {
        actions = Actions(done: onDone, cancel: onCancel, accessibility: onOpenAccessibility)
        hud = Self.panel(frame: hudFrame, keyable: true)
        preview = Self.panel(
            frame: ScrollChromeLayout.preview(region: region, visible: visible), keyable: false)
        preview.ignoresMouseEvents = true
        accessibilityButton = FirstMouseButton(
            title: "Accessibility…", target: actions,
            action: #selector(Actions.openAccessibility))
        cancelButton = FirstMouseButton(
            title: "Cancel", target: actions, action: #selector(Actions.cancelTapped))
        doneButton = FirstMouseButton(
            title: "Done", target: actions, action: #selector(Actions.doneTapped))
        buildHUD()
        buildPreview()
        show(ScrollHUDText.scrolling)
        updateAccessibilityButton()
        heightLabel.stringValue = LengthText.points(0, scale: 1)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAccessibilityButton() }
        }
        preview.orderFrontRegardless()
        hud.makeKeyAndOrderFront(nil)
    }

    public func update(_ session: ScrollSession) {
        show(session.hud)
        updateAccessibilityButton()
        heightLabel.stringValue = session.heightText
        guard session.stitcher.height != shownHeight else { return }
        shownHeight = session.stitcher.height
        // The newest rows, as many as fill the preview at the stitch's width.
        let rows = ScrollChromeLayout.previewRows(
            stitchWidth: session.stitcher.width, size: imageView.bounds.size)
        imageView.image = NSImage(
            cgImage: session.stitcher.bottom(rows: rows).makeImage(), size: .zero)
    }

    /// Shows why the capture couldn't start or ended early, with only OK (Return or Esc), and
    /// returns once it is pressed. The preview closes: nothing more joins the stitch.
    public func explain(_ text: ScrollHUDText) async {
        preview.orderOut(nil)
        show(text)
        accessibilityButton.isHidden = true
        cancelButton.isHidden = true
        doneButton.title = "OK"
        hud.makeKeyAndOrderFront(nil)
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            var resumed = false
            let close = {
                guard !resumed else { return }
                resumed = true
                finished.resume()
            }
            actions.done = close
            actions.cancel = close
            (hud as? KeyablePanel)?.onEscape = close
        }
    }

    public func close() {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        hud.orderOut(nil)
        preview.orderOut(nil)
    }

    private func show(_ text: ScrollHUDText) {
        titleLabel.stringValue = text.title
        detailLabel.stringValue = text.detail
        detailLabel.isHidden = text.detail.isEmpty
        switch text.tone {
        case .progress:
            mark.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .attention:
            showMark("exclamationmark.triangle.fill", .systemOrange)
        case .done:
            showMark("checkmark.circle.fill", .systemGreen)
        }
    }

    private func showMark(_ symbol: String, _ color: NSColor) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        mark.contentTintColor = color
        mark.isHidden = false
    }

    /// Always on screen; enabled only while Excerpt lacks Accessibility access.
    private func updateAccessibilityButton() {
        let trusted = EventScroller.isTrusted
        accessibilityButton.isEnabled = !trusted
        accessibilityButton.toolTip =
            trusted
            ? "Excerpt has Accessibility access" : "Open Privacy & Security → Accessibility"
    }

    private static func panel(frame: CGRect, keyable: Bool) -> NSPanel {
        let panel =
            keyable
            ? KeyablePanel(
                contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false)
            : NSPanel(
                contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background
        return panel
    }

    private func buildHUD() {
        guard let content = hud.contentView else { return }
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let textWidth = ScrollChromeLayout.hudSize.width - 58
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = textWidth
        }
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        mark.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        let status = NSView()
        for view in [spinner, mark] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            status.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: status.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            ])
        }
        status.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 18),
            status.heightAnchor.constraint(equalToConstant: 18),
        ])
        let top = NSStackView(views: [status, text])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 10

        cancelButton.keyEquivalent = "\u{1b}"
        doneButton.keyEquivalent = "\r"
        for button in [accessibilityButton, cancelButton, doneButton] {
            button.controlSize = .small
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [accessibilityButton, spacer, cancelButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let column = NSStackView(views: [top, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .equalSpacing
        column.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -26),
        ])
    }

    private func buildPreview() {
        guard let content = preview.contentView else { return }
        let labelHeight: CGFloat = 22
        imageView.frame = CGRect(
            x: 6, y: labelHeight, width: content.bounds.width - 12,
            height: content.bounds.height - labelHeight - 6)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignBottom
        content.addSubview(imageView)
        heightLabel.frame = CGRect(x: 6, y: 3, width: content.bounds.width - 12, height: 16)
        heightLabel.alignment = .center
        heightLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        content.addSubview(heightLabel)
    }
}

/// The buttons' target: an NSObject the panels can message. `explain` points Done and Cancel at
/// its OK.
@MainActor
private final class Actions: NSObject {
    var done: () -> Void
    var cancel: () -> Void
    let accessibility: () -> Void

    init(
        done: @escaping () -> Void, cancel: @escaping () -> Void,
        accessibility: @escaping () -> Void
    ) {
        self.done = done
        self.cancel = cancel
        self.accessibility = accessibility
    }

    @objc func doneTapped() { done() }
    @objc func cancelTapped() { cancel() }
    @objc func openAccessibility() { accessibility() }
}

/// A borderless panel that can still be key, so its buttons' Return and Esc work. Esc also
/// reaches `onEscape` once Cancel is hidden.
private final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
