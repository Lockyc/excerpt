import AppKit
import ExcerptCapture
import ExcerptCore

/// The library's newest captures in a square floating panel: click copies, drag takes the file
/// out, hover offers Edit, ⌘/⇧-click select several for Edit All, arrows and Return work the
/// selection. It never activates Excerpt, so the app in front keeps focus for the paste, yet it
/// takes keys while shown.
@MainActor
final class RecentCapturesPanel: NSPanel {
    static let glanceBundleID = "com.lockyc.glance"

    private let recentCaptures: () throws -> [URL]
    private let libraryFolder: () -> URL
    private let onEdit: ([URL]) -> Void
    private let onOpenLibrary: () -> Void
    private var captures: [URL] = []
    private var selection = RecentSelection(count: 0)
    private var tiles: [RecentTile] = []
    private let editAllButton = FirstMouseButton(title: "Edit All", target: nil, action: nil)
    private let glanceButton = FirstMouseButton(
        title: "Show All in glance", target: nil, action: nil)
    private var glance: URL?
    private var clickMonitors: [Any] = []

    init(
        recentCaptures: @escaping () throws -> [URL],
        libraryFolder: @escaping () -> URL,
        onEdit: @escaping ([URL]) -> Void,
        onOpenLibrary: @escaping () -> Void
    ) {
        self.recentCaptures = recentCaptures
        self.libraryFolder = libraryFolder
        self.onEdit = onEdit
        self.onOpenLibrary = onOpenLibrary
        let side = RecentLayout.side
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        super.init(
            contentRect: square, styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        // Excerpt is rarely the active app; only Esc, the toggle or a click elsewhere close it.
        hidesOnDeactivate = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: square)
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        for (index, rect) in RecentLayout.tiles(side: side).enumerated() {
            let tile = RecentTile(frame: rect, isHero: index == 0)
            tile.onClick = { [weak self] flags in self?.clicked(index, flags) }
            tile.onEdit = { [weak self] url in self?.finish { self?.onEdit([url]) } }
            tiles.append(tile)
            container.addSubview(tile)
        }

        let footer = NSStackView(frame: RecentLayout.footer(side: side))
        footer.distribution = .fillProportionally
        footer.spacing = 8
        footer.addArrangedSubview(button(editAllButton, #selector(editAllTapped)))
        footer.addArrangedSubview(
            button(
                FirstMouseButton(title: "Open Library Folder", target: nil, action: nil),
                #selector(libraryTapped)))
        footer.addArrangedSubview(button(glanceButton, #selector(glanceTapped)))
        container.addSubview(footer)
        contentView = container
    }

    private func button(_ b: NSButton, _ action: Selector) -> NSButton {
        b.target = self
        b.action = action
        b.bezelStyle = .push
        b.controlSize = .regular
        return b
    }

    /// Keys reach the panel without Excerpt becoming the active app.
    override var canBecomeKey: Bool { true }

    /// Shows the panel centred on the display under the pointer, or closes it.
    func toggle() { if isVisible { close() } else { show() } }

    /// A capture landed: re-read the library so it joins at the top.
    func reloadIfShown() { if isVisible { reload(scale: screen?.backingScaleFactor ?? 2) } }

    /// Thumbnails load for the screen the panel lands on, so it moves there before they do.
    private func show() {
        let pointer = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(
                CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }
        reload(scale: screen?.backingScaleFactor ?? 2)
        makeKeyAndOrderFront(nil)
        // The window itself takes keys, never a footer button under full keyboard access.
        makeFirstResponder(nil)
        let pointerInPanel = mouseLocationOutsideOfEventStream
        for tile in tiles { tile.hovering = NSMouseInRect(pointerInPanel, tile.frame, false) }
        watchClicks()
    }

    /// Re-reads the library into the tiles, thumbnails rendered for a display of `scale`, and
    /// resets the selection.
    private func reload(scale: CGFloat) {
        var note: String?
        do {
            captures = Array(try recentCaptures().prefix(RecentLayout.tileCount))
            if captures.isEmpty { note = "No captures yet" }
        } catch {
            captures = []
            note = "The library folder can't be read"
        }
        let now = Date()
        for (index, tile) in tiles.enumerated() {
            if index < captures.count {
                let url = captures[index]
                let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                tile.show(
                    url, isRecording: LibraryNaming.isRecording(url), scale: scale,
                    age: created.map {
                        CaptureAge.label(created: $0, now: now, calendar: .current)
                    })
            } else {
                tile.showEmpty(note: index == 0 ? note : nil)
            }
        }
        selection = RecentSelection(count: captures.count)
        glance = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.glanceBundleID)
        glanceButton.isEnabled = glance != nil
        glanceButton.toolTip = glance == nil ? "glance isn't installed" : nil
        selectionChanged()
    }

    private var recordingIndices: Set<Int> {
        Set(captures.indices.filter { LibraryNaming.isRecording(captures[$0]) })
    }

    private func selectionChanged() {
        for (index, tile) in tiles.enumerated() {
            tile.isSelected = selection.selected.contains(index)
        }
        let series = selection.series(recordings: recordingIndices)
        editAllButton.isEnabled = series.count >= 2
        editAllButton.toolTip =
            series.count >= 2 ? nil : "Select two or more screenshots with ⌘-click"
    }

    private func clicked(_ index: Int, _ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            selection.toggle(index)
        } else if flags.contains(.shift) {
            selection.extend(to: index)
        } else {
            selection.click(index)
            copy(index)
        }
        selectionChanged()
    }

    /// Copies the capture as its clipboard is filled after it is taken, and says so on its tile.
    private func copy(_ index: Int) {
        guard captures.indices.contains(index) else { return }
        let url = captures[index]
        do {
            if LibraryNaming.isRecording(url) {
                try Pasteboard.copyRecording(at: url)
            } else {
                try Pasteboard.copyPNG(at: url)
            }
            tiles[index].flashCopied()
        } catch {
            Alerts.copyFailed(url, error)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()
        case 123: move(.left)
        case 124: move(.right)
        case 125: move(.down)
        case 126: move(.up)
        case 36, 76:
            // Only a focus that is still selected: after ⌘-click empties the selection, nothing.
            if let focus = selection.focus, selection.selected.contains(focus) { copy(focus) }
        default: super.keyDown(with: event)
        }
    }

    private func move(_ direction: RecentSelection.Direction) {
        selection.move(direction)
        selectionChanged()
    }

    /// Runs an action that hands off elsewhere, closing the panel first.
    private func finish(_ action: () -> Void) {
        close()
        action()
    }

    @objc private func editAllTapped() {
        let urls = selection.series(recordings: recordingIndices).map { captures[$0] }
        finish { onEdit(urls) }
    }

    @objc private func libraryTapped() { finish(onOpenLibrary) }

    @objc private func glanceTapped() {
        guard let glance else { return }
        let folder = libraryFolder()
        finish {
            NSWorkspace.shared.open(
                [folder], withApplicationAt: glance, configuration: .init())
        }
    }

    /// A press anywhere outside the panel closes it: in another app (the global monitor) or in
    /// another of Excerpt's own windows or its menu bar item (the local one).
    private func watchClicks() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let outside: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !NSMouseInRect(NSEvent.mouseLocation, self.frame, false)
                else { return }
                self.close()
            }
        }
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in outside() },
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                if event.window !== self { outside() }
                return event
            },
        ].compactMap { $0 }
    }

    override func close() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        super.close()
    }
}

/// One capture's tile: its thumbnail to click or drag, its age, a play glyph for a recording,
/// Edit while hovered, the selection border, and "Copied" after a copy. Empty, it is a plain
/// fill, the hero carrying a note when the whole library is empty or unreadable.
@MainActor
private final class RecentTile: NSView {
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onEdit: (URL) -> Void = { _ in }
    var isSelected = false { didSet { needsDisplay = true } }
    var hovering = false { didSet { showEdit() } }

    private let isHero: Bool
    private var url: URL?
    private var image: DragImageView?
    private let age = Pill()
    private let copied = Pill()
    private let play: PlayGlyph
    private let note = NSTextField(labelWithString: "")
    private let editButton = FirstMouseButton(title: "Edit", target: nil, action: nil)
    /// Which flash is current, so an older one's timer doesn't hide a newer "Copied".
    private var flash = 0

    init(frame: CGRect, isHero: Bool) {
        self.isHero = isHero
        play = PlayGlyph(pointSize: isHero ? 36 : 22)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        play.centre(in: bounds.size)

        note.alignment = .center
        note.textColor = .secondaryLabelColor
        note.frame = CGRect(x: 8, y: bounds.midY - 10, width: bounds.width - 16, height: 20)

        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.bezelStyle = .push
        editButton.controlSize = isHero ? .regular : .small
        editButton.sizeToFit()
        editButton.setFrameOrigin(
            CGPoint(x: bounds.width - editButton.frame.width - 4, y: 2))
        editButton.isHidden = true

        copied.text = "Copied"
        copied.isHidden = true
        for view in [play, note, age, copied, editButton] as [NSView] { addSubview(view) }

        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Edit shows only on a capture, while the pointer is over it.
    private func showEdit() { editButton.isHidden = !hovering || url == nil }

    /// Shows a capture, its thumbnail loaded at this tile's size for a display of `scale`.
    func show(_ url: URL, isRecording: Bool, scale: CGFloat, age label: String?) {
        self.url = url
        let view = DragImageView(url: url, image: NSImage(size: bounds.size)) {}
        view.frame = bounds
        view.onClick = { [weak self] flags in self?.onClick(flags) }
        replaceImage(with: view)
        CaptureThumbnail.load(url, size: bounds.size, scale: scale) { [weak view] in
            view?.image = $0
        }
        play.isHidden = !isRecording
        note.isHidden = true
        age.text = label ?? ""
        age.isHidden = label == nil
        age.setFrameOrigin(CGPoint(x: 6, y: 6))
        endFlash()
        showEdit()
        needsDisplay = true
    }

    /// Shows an empty tile, carrying `note` when there is one.
    func showEmpty(note text: String?) {
        url = nil
        replaceImage(with: nil)
        play.isHidden = true
        age.isHidden = true
        note.stringValue = text ?? ""
        note.isHidden = text == nil
        endFlash()
        showEdit()
        needsDisplay = true
    }

    private func replaceImage(with view: DragImageView?) {
        image?.removeFromSuperview()
        image = view
        if let view { addSubview(view, positioned: .below, relativeTo: nil) }
    }

    /// "Copied" over the tile for a second.
    func flashCopied() {
        flash += 1
        let current = flash
        copied.setFrameOrigin(
            CGPoint(
                x: (bounds.width - copied.frame.width) / 2,
                y: (bounds.height - copied.frame.height) / 2))
        copied.isHidden = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.flash == current else { return }
            self.copied.isHidden = true
        }
    }

    private func endFlash() {
        flash += 1
        copied.isHidden = true
    }

    @objc private func editTapped() { if let url { onEdit(url) } }

    override var wantsUpdateLayer: Bool { true }

    /// Colours resolve here, under the tile's appearance.
    override func updateLayer() {
        layer?.backgroundColor =
            url == nil ? NSColor.quaternarySystemFill.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

/// A short white label on a dark rounded backing, legible over any thumbnail. It takes no
/// clicks, so a press on it reaches the thumbnail beneath, to copy or drag the file.
@MainActor
private final class Pill: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.sizeToFit()
            setFrameSize(NSSize(width: label.frame.width + 12, height: label.frame.height + 4))
            label.setFrameOrigin(CGPoint(x: 6, y: 2))
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .white
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
