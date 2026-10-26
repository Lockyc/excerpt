import AppKit
import ExcerptCore
import ExcerptRecording

/// The recording editor: the frame at the playhead as the primary renders it, a timeline to
/// trim and scrub, blurs drawn over the frame, the Shortcuts and Clicks toggles and the output
/// format. Save writes the edits and the primary, copies it and closes; Discard closes.
@MainActor
public final class RecordingEditorWindowController: NSWindowController, NSWindowDelegate {
    private static let barHeight: CGFloat = 60
    private static let barMargin: CGFloat = 12
    private static let symbolSize: CGFloat = 18
    /// Playback's frame interval.
    private static let tick = 1.0 / 30
    private static let tools: [Tool] = [.select, .blur]

    private var model: RecordingEditorModel {
        didSet { modelChanged(from: oldValue) }
    }
    private let save: (RecordingEdits) async -> Bool
    private let onClose: () -> Void
    private let preview: FramePreview
    private let frameView: RecordingFrameView
    private let timeline = TimelineView()
    private let toolControl = NSSegmentedControl()
    private let shortcutsBox = NSButton(checkboxWithTitle: "Shortcuts", target: nil, action: nil)
    private let clicksBox = NSButton(checkboxWithTitle: "Clicks", target: nil, action: nil)
    private let formatControl = NSSegmentedControl()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private var player: Timer?
    private var playedFrom: (time: Double, at: Date)?
    private var saving = false
    /// The frame at the playhead couldn't be decoded, so none is shown.
    private var frameUnreadable = false

    /// `master` is the recording and `primary` its rendered file, named on the window;
    /// `defaultFormat` is the format of a master that carries no edits yet. `save` renders the
    /// primary from the edits, writes them to the master and copies the primary, telling the
    /// user of any failure, and returns whether it worked. `onClose` runs once the window has
    /// closed.
    public init(
        master: RecordingMaster, primary: URL, defaultFormat: RecordingFormat = .gif,
        save: @escaping (RecordingEdits) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        model = RecordingEditorModel(master: master, defaultFormat: defaultFormat)
        self.save = save
        self.onClose = onClose
        preview = FramePreview(master: master)
        frameView = RecordingFrameView(pixelSize: master.pixelSize)
        let window = RecordingEditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init(window: window)
        window.delegate = self
        window.editor = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.title = primary.lastPathComponent
        window.representedURL = primary
        buildContent(in: window)
        wire()
        sizeToFit(
            window,
            pointSize: CGSize(
                width: master.pixelSize.width / CGFloat(master.log.scale),
                height: master.pixelSize.height / CGFloat(master.log.scale)))
        window.center()
        preview.onFrame = { [weak self] image in
            guard let self else { return }
            frameView.image = image
            frameUnreadable = image == nil
            update()
        }
        update()
        render()
        let url = master.url
        Task { [weak self] in
            let times = try? await Task.detached { try await RecordingMaster.frameTimes(url) }
                .value
            self?.model.setFrameTimes(times)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(frameView)
    }

    public var hasUnsavedChanges: Bool { model.hasUnsavedChanges }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))

        toolControl.segmentCount = Self.tools.count
        toolControl.trackingMode = .selectOne
        for (i, tool) in Self.tools.enumerated() {
            toolControl.setImage(ToolGlyph.keyed(tool, pointSize: Self.symbolSize), forSegment: i)
            toolControl.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: i)
            toolControl.setWidth(52, forSegment: i)
        }
        toolControl.selectedSegment = 0
        toolControl.target = self
        toolControl.action = #selector(toolChosen)

        shortcutsBox.target = self
        shortcutsBox.action = #selector(shortcutsToggled)
        clicksBox.target = self
        clicksBox.action = #selector(clicksToggled)
        clicksBox.toolTip = "Draw a ring where each click lands"

        formatControl.segmentCount = 2
        formatControl.trackingMode = .selectOne
        formatControl.setLabel("GIF", forSegment: 0)
        formatControl.setToolTip("Save a GIF, fitted to 10 MB", forSegment: 0)
        formatControl.setLabel("MP4", forSegment: 1)
        formatControl.setToolTip("Save an MP4 at full resolution", forSegment: 1)
        formatControl.target = self
        formatControl.action = #selector(formatChosen)

        configure(
            undoButton, symbol: "arrow.uturn.backward", label: "Undo",
            action: #selector(undoPressed))
        configure(
            redoButton, symbol: "arrow.uturn.forward", label: "Redo", action: #selector(redoPressed)
        )
        discardButton.bezelColor = .systemRed
        discardButton.hasDestructiveAction = true
        discardButton.toolTip = "Close without saving"
        discardButton.target = self
        discardButton.action = #selector(discardPressed)
        saveButton.target = self
        saveButton.action = #selector(saveDocument)

        for control in [
            toolControl, shortcutsBox, clicksBox, formatControl, undoButton, redoButton,
            discardButton, saveButton,
        ] as [NSControl] {
            control.refusesFirstResponder = true
            control.controlSize = .large
        }

        let toolGroup = Self.row([toolControl, shortcutsBox, clicksBox, formatControl])
        let actionGroup = Self.row([undoButton, redoButton, discardButton, saveButton])
        let bar = NSView()
        for view in [toolGroup, actionGroup] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolGroup.leadingAnchor.constraint(
                equalTo: bar.leadingAnchor, constant: Self.barMargin),
            actionGroup.leadingAnchor.constraint(
                greaterThanOrEqualTo: toolGroup.trailingAnchor, constant: Self.barMargin),
            actionGroup.trailingAnchor.constraint(
                equalTo: bar.trailingAnchor, constant: -Self.barMargin),
            toolGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            actionGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        configure(playButton, symbol: "play.fill", label: "Play", action: #selector(playPressed))
        playButton.refusesFirstResponder = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let transport = Self.row([playButton, timeline, timeLabel])

        for view in [bar, frameView, transport] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            frameView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            frameView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            transport.topAnchor.constraint(equalTo: frameView.bottomAnchor),
            transport.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.barMargin),
            transport.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.barMargin),
            transport.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            timeline.heightAnchor.constraint(equalToConstant: TimelineView.height),
        ])
        window.contentView = content
        window.minSize = CGSize(
            width: toolGroup.fittingSize.width + actionGroup.fittingSize.width + 3
                * Self.barMargin, height: 360)
    }

    /// The chrome around the frame: the bar above, the transport below.
    private static var chromeHeight: CGFloat {
        barHeight + TimelineView.height + 8 + 2 * RecordingFrameView.gutter
    }

    /// Fits the window to the frame at its size in points, shrunk to fit 90% of the screen.
    private func sizeToFit(_ window: NSWindow, pointSize: CGSize) {
        let visible =
            (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let gutter = 2 * RecordingFrameView.gutter
        let zoom = min(
            1, (visible.width * 0.9 - gutter) / max(pointSize.width, 1),
            (visible.height * 0.9 - Self.chromeHeight) / max(pointSize.height, 1))
        let width = max(pointSize.width * zoom + gutter, window.minSize.width)
        let height = max(pointSize.height * zoom + Self.chromeHeight, window.minSize.height)
        window.setContentSize(CGSize(width: width, height: height))
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Self.symbolSize, weight: .regular))
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    private func wire() {
        timeline.duration = model.duration
        timeline.onScrub = { [weak self] t in
            guard let self, !saving else { return }
            pause()
            model.playhead = t
        }
        timeline.onTrim = { [weak self] trim, continuing in
            guard let self, !saving else { return }
            pause()
            let start = model.edits.trim.lowerBound
            model.setTrim(trim, continuing: continuing)
            // The frame shows the end being dragged.
            model.playhead =
                model.edits.trim.lowerBound != start
                ? model.edits.trim.lowerBound : model.edits.trim.upperBound
        }
        frameView.onDraw = { [weak self] in self?.model.addBlur($0) }
        frameView.onSelect = { [weak self] in self?.model.select($0) }
        frameView.onKey = { [weak self] in self?.handleKey($0) ?? false }
        let bar = frameView.itemBar
        bar.onSpanStart = { [weak self] in
            guard let self, let i = model.selection else { return }
            model.startSpan(ofBlur: i)
        }
        bar.onSpanEnd = { [weak self] in
            guard let self, let i = model.selection else { return }
            model.endSpan(ofBlur: i)
        }
        bar.onWholeClip = { [weak self] in
            guard let self, let i = model.selection else { return }
            model.setSpan(nil, ofBlur: i)
        }
        bar.onDelete = { [weak self] in self?.deleteSelection() }
    }

    // MARK: State

    private func modelChanged(from old: RecordingEditorModel) {
        if model.edits != old.edits || model.playhead != old.playhead
            || model.previewFrameTime != old.previewFrameTime
        {
            render()
        }
        update()
    }

    private func render() {
        preview.request(
            .init(frame: model.previewFrameTime, render: model.playhead), edits: model.edits)
    }

    /// Brings the controls, timeline and frame overlay in line with the model.
    private func update() {
        let edits = model.edits
        let enabled = !saving
        toolControl.selectedSegment = Self.tools.firstIndex(of: frameView.tool) ?? 0
        toolControl.isEnabled = enabled

        let reason = model.shortcutsUnavailableReason
        shortcutsBox.isEnabled = enabled && reason == nil
        shortcutsBox.state = edits.showsShortcuts && reason == nil ? .on : .off
        shortcutsBox.toolTip = reason ?? "Show each shortcut pressed as a pill"
        clicksBox.isEnabled = enabled
        clicksBox.state = edits.showsClicks ? .on : .off
        formatControl.selectedSegment = edits.format == .gif ? 0 : 1
        formatControl.isEnabled = enabled

        undoButton.isEnabled = enabled && model.canUndo
        undoButton.toolTip = model.canUndo ? "Undo (⌘Z)" : "Nothing to undo"
        redoButton.isEnabled = enabled && model.canRedo
        redoButton.toolTip = model.canRedo ? "Redo (⇧⌘Z)" : "Nothing to redo"
        discardButton.isEnabled = enabled
        saveButton.isEnabled = enabled
        saveButton.toolTip = "Save, copy the recording and close (⌘S)"
        playButton.isEnabled = enabled
        let playing = player != nil
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Self.symbolSize, weight: .regular))
        playButton.toolTip = playing ? "Pause (Space)" : "Play (Space)"

        timeline.trim = edits.trim
        timeline.playhead = model.playhead
        timeline.span = model.selection.flatMap { edits.blurs[$0].span }
        timeLabel.stringValue =
            "\(Self.time(model.playhead)) / \(Self.time(model.duration))"

        frameView.isEnabled = enabled
        frameView.blurs = edits.blurs
        frameView.playhead = model.playhead
        frameView.selection = model.selection
        frameView.placeItemBar(options: enabled ? model.itemOptions ?? [] : [])

        let kept = edits.trim.upperBound - edits.trim.lowerBound
        window?.subtitle =
            saving
            ? "Saving…"
            : [
                frameUnreadable ? "This frame couldn't be read" : nil,
                "\(Self.seconds(kept)) of \(Self.seconds(model.duration)) kept",
            ].compactMap { $0 }.joined(separator: " · ")
        window?.isDocumentEdited = model.hasUnsavedChanges
    }

    /// `m:ss.s`.
    private static func time(_ t: Double) -> String {
        let tenths = Int((t * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    private static func seconds(_ t: Double) -> String { String(format: "%.1f s", t) }

    // MARK: Actions

    @objc private func toolChosen() {
        frameView.tool = Self.tools[toolControl.selectedSegment]
        update()
    }

    @objc private func shortcutsToggled() { model.setShowsShortcuts(shortcutsBox.state == .on) }
    @objc private func clicksToggled() { model.setShowsClicks(clicksBox.state == .on) }
    @objc private func formatChosen() {
        model.setFormat(formatControl.selectedSegment == 0 ? .gif : .mp4)
    }
    @objc private func undoPressed() { undo() }
    @objc private func redoPressed() { redo() }

    func undo() {
        guard !saving else { return }
        model.undo()
    }

    func redo() {
        guard !saving else { return }
        model.redo()
    }

    private func deleteSelection() {
        guard let i = model.selection else { return }
        model.removeBlur(i)
    }

    /// Space plays and pauses, `V` and `B` pick the tool, ⌫ deletes the selected blur and Esc
    /// deselects it.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !saving,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        switch event.keyCode {
        case 49:  // Space
            playPressed()
            return true
        case 51, 117:  // ⌫, ⌦
            deleteSelection()
            return true
        case 53:  // Esc
            model.select(nil)
            return true
        default:
            break
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard let tool = Self.tools.first(where: { String($0.key) == key }) else { return false }
        frameView.tool = tool
        update()
        return true
    }

    @objc private func playPressed() {
        if player != nil {
            pause()
            return
        }
        guard !saving else { return }
        if model.playhead >= model.edits.trim.upperBound - Self.tick {
            model.playhead = model.edits.trim.lowerBound
        }
        playedFrom = (model.playhead, Date())
        player = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        update()
    }

    /// Moves the playhead on by the time passed since play, stopping at the trim's end.
    private func advance() {
        guard let playedFrom else { return }
        let t = playedFrom.time + Date().timeIntervalSince(playedFrom.at)
        model.playhead = t
        if t >= model.edits.trim.upperBound { pause() }
    }

    private func pause() {
        guard let player else { return }
        player.invalidate()
        self.player = nil
        playedFrom = nil
        update()
    }

    /// Closes at once, dropping unsaved edits without asking.
    @objc private func discardPressed() {
        pause()
        window?.close()
    }

    /// ⌘S: renders the primary from the edits, writes them to the master, copies it and
    /// closes, edited or not, so what is copied is always the render of the edits shown. A
    /// failed save leaves the window open.
    @objc func saveDocument() {
        write { [weak self] saved in
            if saved { self?.window?.close() }
        }
    }

    /// Hands the edits to `save` with the controls disabled meanwhile, marking them saved when it
    /// worked.
    private func write(then done: @escaping (Bool) -> Void) {
        guard !saving else { return }
        pause()
        let edits = model.edits
        saving = true
        update()
        Task { [weak self] in
            guard let self else { return }
            let saved = await save(edits)
            saving = false
            if saved && model.edits == edits { model.markSaved() }
            update()
            done(saved)
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !saving else { return false }
        guard model.hasUnsavedChanges else { return true }
        confirmClose { [weak self] closes in
            if closes { self?.window?.close() }
        }
        return false
    }

    /// Asks Save / Don't Save / Cancel when there are unsaved edits, then calls `done` with
    /// whether the editor may close: true when nothing is unsaved, on Don't Save, or once Save
    /// worked; false on Cancel or a failed save. Shared by the window's close and the app's quit.
    public func confirmClose(then done: @escaping (Bool) -> Void) {
        guard !saving else { return done(false) }
        guard model.hasUnsavedChanges else { return done(true) }
        pause()
        show()
        let alert = NSAlert()
        alert.messageText = "Save changes to \(window?.title ?? "the recording")?"
        alert.informativeText = "Your edits are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: write(then: done)
        case .alertSecondButtonReturn: done(true)
        default: done(false)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        pause()
        onClose()
    }
}

/// Routes the recording editor's shortcuts itself, as `EditorWindow` does the image editor's.
@MainActor
private final class RecordingEditorWindow: NSWindow {
    weak var editor: RecordingEditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let shortcut = EditorShortcut.allCases.first { $0.modifiers == flags && $0.key == key }
        switch shortcut {
        case .save?: editor?.saveDocument()
        case .close?: performClose(nil)
        case .undo?: editor?.undo()
        case .redo?: editor?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
