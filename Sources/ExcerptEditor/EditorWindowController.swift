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

/// One capture's editor: a floating window fitted to the capture's width, with every tool and
/// action on a toolbar that is always visible, and the canvas in a scroll view; each item's
/// colour, size and own options float beside it on the canvas.
@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    static let toolbarHeight: CGFloat = 60
    private static let snapHint = "⌥ places edges without snapping"

    private let capture: LoadedCapture
    private let save: (EditDocument) throws -> Data
    private let copy: (() throws -> Data) -> Bool
    /// The primary's PNG the last save wrote, and the document it renders: what Save copies
    /// while the document is still that one, instead of rendering and encoding it again.
    private var written: (document: EditDocument, png: Data)?
    private let forClaude: (CGImage, EditDocument) -> Void
    private let onClose: () -> Void
    private let model: EditorModel
    private let canvas: CanvasView
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

    /// `save` writes the document (the app's `LibraryStore.saveEdits`) and returns the primary's
    /// PNG it wrote; `copy`, Save's last
    /// step, is handed a closure that renders the current PNG, puts it on the pasteboard,
    /// reports any failure, the render's included, and returns whether it worked; `forClaude`
    /// exports the original with the current edits; `borderStyle` is the border a capture
    /// without one gets when turned on, and `rememberBorder` is told each colour or width the
    /// user picks; `annotationStyle` is what new annotations start with, and `rememberStyle` is
    /// told each colour, size or background the user picks; `onClose` runs once the window has
    /// closed.
    public init(
        capture: LoadedCapture, save: @escaping (EditDocument) throws -> Data,
        copy: @escaping (() throws -> Data) -> Bool,
        forClaude: @escaping (CGImage, EditDocument) -> Void, borderStyle: Border,
        rememberBorder: @escaping (Border) -> Void, annotationStyle: AnnotationStyle,
        rememberStyle: @escaping (AnnotationStyle) -> Void, onClose: @escaping () -> Void
    ) {
        self.capture = capture
        self.save = save
        self.copy = copy
        self.forClaude = forClaude
        self.onClose = onClose
        model = EditorModel(
            original: capture.original, document: capture.edits, borderStyle: borderStyle,
            style: annotationStyle)
        model.onBorderStyleChange = rememberBorder
        model.onStyleChange = rememberStyle
        canvas = CanvasView(model: model)
        borderPanel = BorderPanel(model: model)
        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        super.init(window: window)
        window.delegate = self
        window.editor = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.title = capture.primary.lastPathComponent
        window.representedURL = capture.primary
        buildContent(in: window)
        // The canvas owns the model's change hook and forwards every change here.
        canvas.onChange = { [weak self] in self?.update() }
        sizeToFit(window)
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
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
        scrollView.documentView = canvas
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
            object: clip)

        for view in [bar, scrollView] as [NSView] {
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
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
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

    /// Opens at the capture's size in points, shrunk to fit 90% of the screen; tall captures
    /// scroll.
    private func sizeToFit(_ window: NSWindow) {
        let visible =
            (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = CGFloat(model.document.scale)
        let rendered = max(canvas.renderedSize.width, 1)
        let width = min(max(rendered / scale, window.minSize.width), visible.width * 0.9)
        let zoom = min(width / rendered, 1 / scale)
        let height = min(
            canvas.renderedSize.height * zoom + Self.toolbarHeight, visible.height * 0.9)
        window.setContentSize(CGSize(width: width, height: max(height, 300)))
        window.center()
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
        window?.subtitle = [hint, model.hiddenNote(map: canvas.base.map)]
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
        saveButton.toolTip =
            model.isDirty
            ? "Save, copy the image and close (⌘S)" : "Copy the image and close (⌘S)"
        window?.isDocumentEdited = model.isDirty
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
            forClaude(model.original, model.document)
            return true
        }
    }

    /// ⌘S: writes unsaved edits, puts the image on the clipboard and closes. With nothing
    /// unsaved there is nothing to write, so an unedited capture stays one file.
    @objc func saveDocument() {
        let original = model.original
        finish {
            let document = model.document
            let written = written
            return copy {
                if let written, written.document == document { return written.png }
                let image = Renderer.render(original, edits: document).image
                return try PNGCodec.encode(image, scale: document.scale)
            }
        }
    }

    /// Save and For Claude each end the edit: unsaved edits are written (the master keeps
    /// the original, so they stay adjustable), then `action` runs, then the window closes. A
    /// failed save or action leaves it open.
    private func finish(_ action: () -> Bool) {
        canvas.commitInProgress()
        guard !model.isDirty || writeDocument(), action() else { return }
        window?.close()
    }

    func undo() {
        canvas.commitInProgress()
        model.undo()
    }

    func redo() {
        canvas.commitInProgress()
        model.redo()
    }

    /// Writes the primary and master; false (after telling the user) when that failed.
    private func writeDocument() -> Bool {
        canvas.commitInProgress()
        do {
            let document = model.document
            written = (document, try save(document))
            model.markSaved()
            update()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save \(capture.primary.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return false
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }

    /// True when nothing is unsaved, or the user chose Save (and it worked) or Don't Save;
    /// false on Cancel or a failed save. Shared by the window's close and the app's quit.
    public func confirmClose() -> Bool {
        canvas.commitInProgress()
        guard model.isDirty else { return true }
        show()
        let alert = NSAlert()
        alert.messageText = "Save changes to \(capture.primary.lastPathComponent)?"
        alert.informativeText = "Your edits are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return writeDocument()
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
    case save, forClaude, close, cut, copy, paste, selectAll, undo, redo

    /// The command as the user knows it.
    public var name: String {
        switch self {
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
