import AppKit
import ExcerptCore

/// Keeps a document narrower than the window centred horizontally, and (being flipped) sits a
/// document shorter than the window at the top.
@MainActor
private final class CenteringClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        if let document = documentView, document.frame.width < rect.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        return rect
    }
}

/// One capture in the editor: its model, the canvas that draws it, and what its last save wrote.
@MainActor
private final class Page {
    let capture: LoadedCapture
    let model: EditorModel
    let canvas: CanvasView
    /// The primary's PNG the last save wrote, and the document it renders: what Save copies
    /// while the document is still that one, instead of rendering and encoding it again.
    var written: (document: EditDocument, png: Data)?

    init(capture: LoadedCapture, model: EditorModel) {
        self.capture = capture
        self.model = model
        canvas = CanvasView(model: model)
    }

    /// The PNG Save copies: the one last written while it still renders the document.
    func png() throws -> Data {
        let document = model.document
        if let written, written.document == document { return written.png }
        let image = Renderer.render(model.original, edits: document).image
        return try PNGCodec.encode(image, scale: document.scale)
    }
}

/// The editor: a floating window fitted to the capture's width, with every tool and action on a
/// toolbar that is always visible, and the canvas in a scroll view; each item's colour, size and
/// own options float beside it on the canvas. Over a series of captures a filmstrip along the
/// bottom moves between them, and step numbers carry on from one capture to the next.
@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    static let toolbarHeight: CGFloat = 60
    private static let snapHint = "⌥ places edges without snapping"

    private let pages: [Page]
    /// The capture in view.
    public private(set) var current = 0
    private let save: (LoadedCapture, EditDocument) throws -> Data
    private let copy: (() throws -> [Data]) -> Bool
    private let forClaude: (LoadedCapture, CGImage, EditDocument) -> Void
    private let onClose: () -> Void
    private var page: Page { pages[current] }
    private var model: EditorModel { page.model }
    private var canvas: CanvasView { page.canvas }
    /// Only over a series.
    private let filmstrip: Filmstrip?
    private var renumbering = false
    private let scrollView = NSScrollView()
    private let tools = NSSegmentedControl()
    /// A split control: "Border" turns the border on and off, the chevron drops down its
    /// settings.
    private let borderControl = NSSegmentedControl()
    private let borderPanel: BorderPanel
    private let borderPopover = NSPopover()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let discardButton = NSButton(title: "Discard", target: nil, action: nil)
    private let claudeButton = NSButton(title: "For Claude", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    /// While the app prepares this capture for Claude, For Claude is disabled and says why.
    public var isPreparingForClaude = false {
        didSet { update() }
    }

    /// `captures` is the series in order, one capture for a plain editor. `save` writes a
    /// capture's document (the app's `LibraryStore.saveEdits`) and returns the primary's PNG it
    /// wrote; `copy`, Save's last step, is handed a closure that renders every capture's PNG in
    /// order, puts them on the pasteboard, reports any failure, the render's included, and
    /// returns whether it worked; `forClaude` exports the capture in view with its current
    /// edits; `borderStyle` is the border a capture without one gets when turned on, and
    /// `rememberBorder` is told each colour or width the user picks; `annotationStyle` is what
    /// new annotations start with, and `rememberStyle` is told each colour, size or background
    /// the user picks; `marginColor` fills the margin of a capture that has none yet; `onClose`
    /// runs once the window has closed.
    public init(
        captures: [LoadedCapture], save: @escaping (LoadedCapture, EditDocument) throws -> Data,
        copy: @escaping (() throws -> [Data]) -> Bool,
        forClaude: @escaping (LoadedCapture, CGImage, EditDocument) -> Void,
        borderStyle: Border, rememberBorder: @escaping (Border) -> Void,
        annotationStyle: AnnotationStyle, rememberStyle: @escaping (AnnotationStyle) -> Void,
        marginColor: RGBA? = nil, onClose: @escaping () -> Void
    ) {
        precondition(!captures.isEmpty, "an editor needs a capture")
        self.save = save
        self.copy = copy
        self.forClaude = forClaude
        self.onClose = onClose
        pages = captures.map { capture in
            let model = EditorModel(
                original: capture.original, document: capture.edits, borderStyle: borderStyle,
                style: annotationStyle, marginColor: marginColor)
            model.onBorderStyleChange = rememberBorder
            model.onStyleChange = rememberStyle
            return Page(capture: capture, model: model)
        }
        filmstrip = captures.count > 1 ? Filmstrip(count: captures.count) : nil
        borderPanel = BorderPanel(model: pages[0].model)
        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init(window: window)
        window.delegate = self
        window.editor = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        buildContent(in: window)
        for (i, page) in pages.enumerated() {
            // Each canvas owns its model's change hook and forwards every change here.
            page.canvas.onChange = { [weak self] in self?.changed(i) }
        }
        filmstrip?.onSelect = { [weak self] in self?.show(capture: $0) }
        filmstrip?.onRestart = { [weak self] i, on in
            guard let self else { return }
            if i == current { canvas.commitInProgress() }
            pages[i].model.setRestartsSteps(on)
        }
        renumber()
        for i in pages.indices { refreshThumbnail(i) }
        present(current)
        sizeToFit(window)
        window.center()
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    /// Every capture's primary, in series order.
    public var primaries: [URL] { pages.map(\.capture.primary) }

    func model(at index: Int) -> EditorModel { pages[index].model }

    /// Shows another capture of the series, carrying the tool and style over; out of range
    /// does nothing.
    public func show(capture index: Int) {
        guard pages.indices.contains(index), index != current else { return }
        canvas.commitInProgress()
        // A drag in flight would end on a canvas no longer in the window.
        if model.drag != nil { model.cancelDrag() }
        let tool = model.tool
        let style = model.style
        refreshThumbnail(current)
        current = index
        model.adopt(tool: tool, style: style)
        present(index)
        if let window { sizeToFit(window) }
        update()
        window?.makeFirstResponder(canvas)
    }

    /// Puts capture `index`'s canvas in the scroll view and its name on the window.
    private func present(_ index: Int) {
        let page = pages[index]
        scrollView.documentView = page.canvas
        borderPanel.model = page.model
        filmstrip?.current = index
        window?.title = page.capture.primary.lastPathComponent
        window?.representedURL = page.capture.primary
    }

    /// A capture's document, tool or selection changed.
    private func changed(_ index: Int) {
        renumber()
        if index == current { update() }
    }

    /// Carries step numbers on through the series: each capture's first step follows the
    /// capture before's last, unless it restarts.
    /// A capture on its own keeps the numbers it was saved with.
    private func renumber() {
        guard !renumbering, pages.count > 1 else { return }
        renumbering = true
        defer { renumbering = false }
        let firsts = SeriesNumbering.firstSteps(
            stepCounts: pages.map(\.model.stepCount),
            restarts: pages.map(\.model.document.restartsSteps))
        for (i, page) in pages.enumerated() {
            let model = page.model
            if model.document.firstStep != firsts[i] {
                model.setFirstStep(firsts[i])
                if i != current { refreshThumbnail(i) }
            }
            filmstrip?.setSteps(
                first: firsts[i], count: model.stepCount,
                restarts: model.document.restartsSteps, at: i)
        }
    }

    private func refreshThumbnail(_ index: Int) {
        guard let filmstrip else { return }
        let model = pages[index].model
        filmstrip.setImage(Renderer.render(model.original, edits: model.document).image, at: index)
    }

    // MARK: Layout

    private func buildContent(in window: NSWindow) {
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))

        tools.segmentCount = Tool.allCases.count
        tools.trackingMode = .selectOne
        for (i, tool) in Tool.allCases.enumerated() {
            tools.setImage(ToolGlyph.keyed(tool, pointSize: Self.symbolSize), forSegment: i)
            tools.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: i)
            tools.setWidth(52, forSegment: i)
        }
        tools.target = self
        tools.action = #selector(toolChosen)

        borderControl.segmentCount = 2
        borderControl.trackingMode = .selectAny
        borderControl.setLabel("Border", forSegment: 0)
        borderControl.setToolTip("Border on or off", forSegment: 0)
        borderControl.setImage(Self.symbol("chevron.down", label: "Border settings"), forSegment: 1)
        borderControl.setWidth(30, forSegment: 1)
        borderControl.setToolTip("Border colour and width", forSegment: 1)
        borderControl.target = self
        borderControl.action = #selector(borderPressed)
        borderPopover.contentViewController = borderPanel
        borderPopover.behavior = .transient

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
        claudeButton.target = self
        claudeButton.action = #selector(forClaudePressed)
        saveButton.target = self
        saveButton.action = #selector(saveDocument)

        for control in [
            tools, borderControl, undoButton, redoButton, discardButton,
            claudeButton, saveButton,
        ] as [NSControl] {
            control.refusesFirstResponder = true
            control.controlSize = .large
        }

        // One row: the tools centred on the window while there is room, pushed left of the
        // actions when there isn't; the actions at the right.
        let toolGroup = Self.row([tools, borderControl])
        let actionGroup = Self.row(
            [undoButton, redoButton, discardButton, claudeButton, saveButton])
        let bar = NSView()
        for view in [toolGroup, actionGroup] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        let centred = toolGroup.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        // Below the window's hold on its size, so centring never widens the window.
        centred.priority = .dragThatCannotResizeWindow
        NSLayoutConstraint.activate([
            centred,
            toolGroup.leadingAnchor.constraint(
                greaterThanOrEqualTo: bar.leadingAnchor, constant: Self.barMargin),
            actionGroup.leadingAnchor.constraint(
                greaterThanOrEqualTo: toolGroup.trailingAnchor, constant: Self.barMargin),
            actionGroup.trailingAnchor.constraint(
                equalTo: bar.trailingAnchor, constant: -Self.barMargin),
            toolGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            actionGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .underPageBackgroundColor
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
            object: clip)

        for view in [bar, scrollView, filmstrip].compactMap({ $0 }) as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        if let filmstrip {
            NSLayoutConstraint.activate([
                filmstrip.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
                filmstrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                filmstrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                filmstrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                filmstrip.heightAnchor.constraint(equalToConstant: Filmstrip.height),
            ])
        } else {
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        }
        window.contentView = content
        // As narrow as the tools and actions fit side by side.
        window.minSize = CGSize(
            width: toolGroup.fittingSize.width + actionGroup.fittingSize.width + 3
                * Self.barMargin, height: 300)
    }

    private static let barMargin: CGFloat = 12

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    /// Toolbar symbols are drawn large to match the large controls.
    private static let symbolSize: CGFloat = 18

    private static func symbol(_ name: String, label: String?) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular))
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = Self.symbol(symbol, label: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    /// Fits the window to the capture in view at its size in points, shrunk to fit 90% of the
    /// screen, its top edge kept where it was unless that would take it off the bottom of the
    /// screen; tall captures scroll.
    private func sizeToFit(_ window: NSWindow) {
        let visible =
            (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = CGFloat(model.document.scale)
        let rendered = max(canvas.renderedSize.width, 1)
        let width = min(max(rendered / scale, window.minSize.width), visible.width * 0.9)
        let zoom = min(width / rendered, 1 / scale)
        let chrome = Self.toolbarHeight + (filmstrip == nil ? 0 : Filmstrip.height)
        let height = min(canvas.renderedSize.height * zoom + chrome, visible.height * 0.9)
        let topLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(CGSize(width: width, height: max(height, 300)))
        window.setFrameTopLeftPoint(topLeft)
        if window.frame.minY < visible.minY {
            window.setFrameOrigin(CGPoint(x: window.frame.minX, y: visible.minY))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        fitWidth()
    }

    /// Fits the capture to the window's width, never past its size in points. A zero-width
    /// layout pass (before the window has a size) leaves the zoom alone.
    private func fitWidth() {
        let available = scrollView.contentSize.width
        guard available > 0 else { return }
        let scale = CGFloat(model.document.scale)
        let zoom = min(available / max(canvas.renderedSize.width, 1), 1 / scale)
        guard zoom != canvas.zoom else { return }
        canvas.zoom = zoom
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The width to fit changes with the window, and also without it: the scroller style can
    /// settle after the window shows, and a legacy scroller takes its width from the view.
    @objc private func clipResized() { fitWidth() }

    /// Brings the toolbar, title and note in line with the model.
    private func update() {
        tools.selectedSegment = Tool.allCases.firstIndex(of: model.tool) ?? 0
        borderControl.setSelected(model.document.border != nil, forSegment: 0)
        borderPanel.refresh()
        let limit = model.tool == .cut ? model.cutLimitNote : ""
        let hint =
            !limit.isEmpty ? limit : model.tool == .cut || model.tool == .crop ? Self.snapHint : ""
        window?.subtitle = [hint, model.hiddenNote(map: canvas.map)]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        undoButton.isEnabled = model.canUndo
        undoButton.toolTip = model.canUndo ? "Undo (⌘Z)" : "Nothing to undo"
        redoButton.isEnabled = model.canRedo
        redoButton.toolTip = model.canRedo ? "Redo (⇧⌘Z)" : "Nothing to redo"
        claudeButton.isEnabled = !isPreparingForClaude
        claudeButton.toolTip =
            isPreparingForClaude
            ? "Preparing for Claude…"
            : "Save, copy tiles and text of the image for Claude and close (⇧⌘C)"
        let images = pages.count == 1 ? "the image" : "the \(pages.count) images"
        saveButton.toolTip =
            isDirty ? "Save, copy \(images) and close (⌘S)" : "Copy \(images) and close (⌘S)"
        window?.isDocumentEdited = isDirty
        fitWidth()  // a column cut changes the rendered width
    }

    // MARK: Actions

    /// Reads the chosen segment before committing, since the commit's update re-selects the
    /// current tool's.
    @objc private func toolChosen() {
        let chosen = Tool.allCases[tools.selectedSegment]
        canvas.commitInProgress()
        model.tool = chosen
    }

    /// "Border" turns the border on or off; the chevron drops down its settings.
    @objc private func borderPressed() {
        // Read before committing, whose update re-selects the segments from the model.
        let settings = borderControl.isSelected(forSegment: 1)
        let border = borderControl.isSelected(forSegment: 0)
        canvas.commitInProgress()
        // The chevron never stays selected, so a click on it is the one that selects it.
        guard settings else {
            model.setBorder(border)
            return
        }
        borderControl.setSelected(false, forSegment: 1)
        if borderPopover.isShown {
            borderPopover.close()
        } else {
            borderPanel.refresh()
            borderPopover.show(
                relativeTo: borderControl.bounds, of: borderControl, preferredEdge: .maxY)
        }
    }

    @objc private func undoPressed() { undo() }
    @objc private func redoPressed() { redo() }

    /// Closes at once, dropping unsaved edits without asking.
    @objc private func discardPressed() {
        canvas.commitInProgress()
        window?.close()
    }

    /// ⇧⌘C: like Save, it writes unsaved edits first, so what Claude reads is what the library
    /// holds.
    @objc func forClaudePressed() {
        finish {
            forClaude(page.capture, model.original, model.document)
            return true
        }
    }

    /// ⌘S: writes unsaved edits, puts every image on the clipboard in order and closes. With
    /// nothing unsaved there is nothing to write, so an unedited capture stays one file.
    @objc func saveDocument() {
        let pages = pages
        finish { copy { try pages.map { try $0.png() } } }
    }

    /// Save and For Claude each end the edit: every capture's unsaved edits are written (the
    /// master keeps the original, so they stay adjustable), then `action` runs, then the window
    /// closes. A failed save or action leaves it open.
    private func finish(_ action: () -> Bool) {
        canvas.commitInProgress()
        guard writeDocuments(), action() else { return }
        window?.close()
    }

    private var isDirty: Bool { pages.contains { $0.model.isDirty } }

    func undo() {
        canvas.commitInProgress()
        model.undo()
    }

    func redo() {
        canvas.commitInProgress()
        model.redo()
    }

    /// Writes the primary and master of every capture with unsaved edits; false (after telling
    /// the user) at the first that failed.
    private func writeDocuments() -> Bool {
        canvas.commitInProgress()
        defer { update() }
        for page in pages where page.model.isDirty {
            do {
                let document = page.model.document
                page.written = (document, try save(page.capture, document))
                page.model.markSaved()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save \(page.capture.primary.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return false
            }
        }
        return true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

    /// True when nothing is unsaved, or the user chose Save (and it worked) or Don't Save;
    /// false on Cancel or a failed save. Shared by the window's close and the app's quit.
    public func confirmClose() -> Bool {
        canvas.commitInProgress()
        let dirty = pages.filter(\.model.isDirty)
        guard let first = dirty.first else { return true }
        show()
        let alert = NSAlert()
        alert.messageText =
            dirty.count == 1
            ? "Save changes to \(first.capture.primary.lastPathComponent)?"
            : "Save changes to \(dirty.count) captures?"
        alert.informativeText = "Your edits are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return writeDocuments()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    public func windowWillClose(_ notification: Notification) { onClose() }
}

/// A key equivalent the editor handles itself. The one table of them: `EditorWindow` dispatches
/// on it, and the app refuses to bind a global hotkey to any, since a global hotkey takes the
/// press before the editor sees it.
public enum EditorShortcut: CaseIterable, Sendable {
    case save, forClaude, close, cut, copy, paste, selectAll, undo, redo, previous, next

    /// The command as the user knows it.
    public var name: String {
        switch self {
        case .previous: "Previous Capture"
        case .next: "Next Capture"
        case .save: "Save"
        case .forClaude: "For Claude"
        case .close: "Close"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .undo: "Undo"
        case .redo: "Redo"
        }
    }

    /// The lowercased key, as `charactersIgnoringModifiers` reports it.
    public var key: String {
        switch self {
        case .save: "s"
        case .forClaude, .copy: "c"
        case .close: "w"
        case .cut: "x"
        case .paste: "v"
        case .selectAll: "a"
        case .undo, .redo: "z"
        case .previous: "["
        case .next: "]"
        }
    }

    public var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .forClaude, .redo: [.command, .shift]
        default: [.command]
        }
    }
}

/// Routes the editor's shortcuts itself: an accessory app has no menu bar to carry them.
@MainActor
final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard
            let shortcut = EditorShortcut.allCases.first(where: {
                $0.modifiers == flags && $0.key == key
            })
        else { return super.performKeyEquivalent(with: event) }
        // Save, For Claude and close work everywhere, including while a text field is being
        // edited.
        switch shortcut {
        case .save:
            editor?.saveDocument()
            return true
        case .forClaude:
            editor?.forClaudePressed()
            return true
        case .close:
            performClose(nil)
            return true
        case .previous, .next:
            if let editor { editor.show(capture: editor.current + (shortcut == .next ? 1 : -1)) }
            return true
        default:
            break
        }
        // Without a main menu nothing translates the edit shortcuts, so a field being edited
        // gets them here.
        if firstResponder is NSTextView {
            let action: Selector
            switch shortcut {
            case .cut: action = #selector(NSText.cut(_:))
            case .copy: action = #selector(NSText.copy(_:))
            case .paste: action = #selector(NSText.paste(_:))
            case .selectAll: action = #selector(NSText.selectAll(_:))
            case .undo: action = Selector(("undo:"))
            case .redo: action = Selector(("redo:"))
            default: return super.performKeyEquivalent(with: event)
            }
            return NSApp.sendAction(action, to: nil, from: self)
        }
        switch shortcut {
        case .undo: editor?.undo()
        case .redo: editor?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
