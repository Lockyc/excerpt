import AVFoundation
import AppKit
import ExcerptCore
import ExcerptRecording

/// The master's frame at a time, rendered with the edits through `RecordingRenderer`, the
/// renderer that writes the primary. Only the latest request renders: one asked for while
/// another is rendering replaces any still waiting, so scrubbing and playback never queue.
@MainActor
private final class FramePreview {
    private let generator: AVAssetImageGenerator
    private let log: RecordingEventLog
    /// The last time a frame can be read at.
    private let lastTime: Double
    /// The last frame decoded, kept so a change of edits re-renders without decoding.
    private var decoded: (time: Double, image: CGImage)?
    private var pending: (time: Double, edits: RecordingEdits)?
    private var busy = false
    var onFrame: (CGImage) -> Void = { _ in }

    init(master: RecordingMaster) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: master.url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        log = master.log
        lastTime = max(master.duration - 1.0 / 600, 0)
    }

    func request(at t: Double, edits: RecordingEdits) {
        pending = (t, edits)
        guard !busy else { return }
        busy = true
        Task { await drain() }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            guard let frame = await frame(at: next.time) else { continue }
            let log = log
            let rendered = await Task.detached(priority: .userInitiated) {
                RecordingRenderer.render(
                    frame, at: next.time, log: log, edits: next.edits, outputScale: 1)
            }.value
            onFrame(rendered)
        }
        busy = false
    }

    private func frame(at t: Double) async -> CGImage? {
        if let decoded, decoded.time == t { return decoded.image }
        let time = CMTime(seconds: min(t, lastTime), preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        decoded = (t, image)
        return image
    }
}

/// The rendered frame, fitted to the view, with every blur's outline over it: drawn under the
/// blur tool, selected with a click, the selection's item bar above it.
@MainActor
private final class RecordingFrameView: NSView {
    static let gutter: CGFloat = 12

    let pixelSize: CGSize
    var image: CGImage? {
        didSet { needsDisplay = true }
    }
    var blurs: [RecordingBlur] = [] {
        didSet { needsDisplay = true }
    }
    var playhead: Double = 0 {
        didSet { needsDisplay = true }
    }
    var selection: Int? {
        didSet { needsDisplay = true }
    }
    var tool: Tool = .select {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var isEnabled = true
    let itemBar = ItemBar()
    /// A blur drawn, in master pixels with a top-left origin.
    var onDraw: (CGRect) -> Void = { _ in }
    var onSelect: (Int?) -> Void = { _ in }
    /// A key the view doesn't handle itself; true when it was used.
    var onKey: (NSEvent) -> Bool = { _ in false }

    private var drawing: (anchor: CGPoint, current: CGPoint)?

    init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
        super.init(frame: .zero)
        itemBar.isHidden = true
        addSubview(itemBar)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the frame is drawn: fitted inside the gutter, never past its size in points.
    var imageRect: CGRect {
        let area = bounds.insetBy(dx: Self.gutter, dy: Self.gutter)
        guard pixelSize.width > 0, pixelSize.height > 0, area.width > 0, area.height > 0 else {
            return .zero
        }
        let zoom = min(area.width / pixelSize.width, area.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * zoom, height: pixelSize.height * zoom)
        return CGRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
            height: size.height)
    }

    private var zoom: CGFloat { imageRect.width / max(pixelSize.width, 1) }

    private func viewRect(_ pixels: CGRect) -> CGRect {
        let image = imageRect
        return CGRect(
            x: image.minX + pixels.minX * zoom, y: image.minY + pixels.minY * zoom,
            width: pixels.width * zoom, height: pixels.height * zoom)
    }

    private func pixelRect(_ view: CGRect) -> CGRect {
        let image = imageRect
        let zoom = max(zoom, .ulpOfOne)
        return CGRect(
            x: (view.minX - image.minX) / zoom, y: (view.minY - image.minY) / zoom,
            width: view.width / zoom, height: view.height / zoom)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState()
        // The view is flipped; the image is drawn upright.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()

        for (i, blur) in blurs.enumerated() {
            let shown = blur.span?.contains(playhead) ?? true
            let path = NSBezierPath(rect: viewRect(blur.rect).insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = i == selection ? 2 : 1
            if !shown { path.setLineDash([4, 3], count: 2, phase: 0) }
            (i == selection ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.8))
                .setStroke()
            path.stroke()
        }
        if let drawing {
            let path = NSBezierPath(rect: Self.rect(drawing.anchor, drawing.current))
            path.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    override func layout() {
        super.layout()
        placeItemBar()
    }

    /// Above the selected blur, left-aligned with it; below it when there is no room above;
    /// kept inside the view. Hidden while a blur is being drawn.
    func placeItemBar(options: [ItemOption]? = nil) {
        if let options { itemBar.show(options) }
        guard let selection, blurs.indices.contains(selection), drawing == nil, options != [] else {
            itemBar.isHidden = true
            return
        }
        let size = itemBar.frame.size
        let rect = viewRect(blurs[selection].rect)
        let gap: CGFloat = 6
        let above = rect.minY - size.height - gap
        let y = above >= 4 ? above : min(rect.maxY + gap, bounds.maxY - size.height - 4)
        let x = min(max(rect.minX, 4), max(4, bounds.maxX - size.width - 4))
        itemBar.frame = CGRect(origin: CGPoint(x: x, y: max(4, y)), size: size)
        itemBar.isHidden = false
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: ToolGlyph.cursor(tool))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = blurs.indices.last(where: { viewRect(blurs[$0].rect).contains(point) }) {
            onSelect(hit)
        } else if tool == .blur && imageRect.contains(point) {
            drawing = (point, point)
            itemBar.isHidden = true
        } else {
            onSelect(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawing != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let image = imageRect
        drawing?.current = CGPoint(
            x: min(max(point.x, image.minX), image.maxX),
            y: min(max(point.y, image.minY), image.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drawing else { return }
        self.drawing = nil
        needsDisplay = true
        let rect = Self.rect(drawing.anchor, drawing.current)
        if rect.width >= 4 && rect.height >= 4 {
            onDraw(pixelRect(rect))
        } else {
            onSelect(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

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
    private let save: (RecordingEdits, _ changed: Bool) async -> Bool
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

    /// `master` is the recording and `primary` its rendered file, named on the window;
    /// `defaultFormat` is the format of a master that carries no edits yet. `save` writes the
    /// edits to the master, renders the primary and copies it, or with `changed` false only
    /// copies, telling the user of any failure, and returns whether it worked. `onClose` runs once
    /// the window has closed.
    public init(
        master: RecordingMaster, primary: URL, defaultFormat: RecordingFormat = .gif,
        save: @escaping (RecordingEdits, _ changed: Bool) async -> Bool,
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
        preview.onFrame = { [weak self] in self?.frameView.image = $0 }
        update()
        render()
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
        if model.edits != old.edits || model.playhead != old.playhead { render() }
        update()
    }

    private func render() { preview.request(at: model.playhead, edits: model.edits) }

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
        saveButton.toolTip =
            model.hasUnsavedChanges
            ? "Save, copy the recording and close (⌘S)" : "Copy the recording and close (⌘S)"
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
            : "\(Self.seconds(kept)) of \(Self.seconds(model.duration)) kept"
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

    /// ⌘S: writes the edits and the primary, copies it and closes; with nothing unsaved it only
    /// copies. A failed save leaves the window open.
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
        let changed = model.hasUnsavedChanges
        saving = true
        update()
        Task { [weak self] in
            guard let self else { return }
            let saved = await save(edits, changed)
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
