import AppKit
import ExcerptCore

extension StrokeWidth {
    /// The size control's segment label.
    var label: String {
        switch self {
        case .thin: "S"
        case .medium: "M"
        case .thick: "L"
        }
    }
}

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

/// One capture's editor: a floating window fitted to the capture's width, with every tool,
/// colour, size and action on a toolbar that is always visible, and the canvas in a scroll view.
@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    static let toolbarHeight: CGFloat = 68
    static let minimumWidth: CGFloat = 720
    private static let snapHint = "⌥ places edges without snapping"

    private let capture: LoadedCapture
    private let save: (EditDocument) throws -> Void
    private let copy: (() throws -> Data) -> Void
    private let onClose: () -> Void
    private let model: EditorModel
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let tools = NSSegmentedControl()
    private let colors = NSSegmentedControl()
    private let widths = NSSegmentedControl()
    private let snapHint = NSTextField(labelWithString: "")
    private let hiddenNote = NSTextField(labelWithString: "")
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let deleteButton = NSButton()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    /// `save` writes the document (the app's `LibraryStore.saveEdits`); `copy` is handed a
    /// closure that renders the current PNG, puts it on the pasteboard and reports any failure,
    /// the render's included; `onClose` runs once the window has closed.
    public init(
        capture: LoadedCapture, save: @escaping (EditDocument) throws -> Void,
        copy: @escaping (() throws -> Data) -> Void, onClose: @escaping () -> Void
    ) {
        self.capture = capture
        self.save = save
        self.copy = copy
        self.onClose = onClose
        model = EditorModel(original: capture.original, document: capture.edits)
        canvas = CanvasView(model: model)
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
        window.minSize = CGSize(width: Self.minimumWidth, height: 300)
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
            tools.setImage(
                NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title),
                forSegment: i)
            tools.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: i)
            tools.setWidth(30, forSegment: i)
        }
        tools.target = self
        tools.action = #selector(toolChosen)

        colors.segmentCount = Palette.allCases.count
        colors.trackingMode = .selectOne
        for (i, color) in Palette.allCases.enumerated() {
            colors.setImage(Self.swatch(color), forSegment: i)
            colors.setToolTip(color.rawValue.capitalized, forSegment: i)
            colors.setWidth(26, forSegment: i)
        }
        colors.target = self
        colors.action = #selector(colorChosen)

        widths.segmentCount = StrokeWidth.allCases.count
        widths.trackingMode = .selectOne
        for (i, width) in StrokeWidth.allCases.enumerated() {
            widths.setLabel(width.label, forSegment: i)
            widths.setToolTip(
                "\(Int(width.points))pt stroke · \(Int(width.textPoints))pt text", forSegment: i)
            widths.setWidth(28, forSegment: i)
        }
        widths.target = self
        widths.action = #selector(widthChosen)

        for label in [snapHint, hiddenNote] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        configure(
            undoButton, symbol: "arrow.uturn.backward", label: "Undo",
            action: #selector(undoPressed))
        configure(
            redoButton, symbol: "arrow.uturn.forward", label: "Redo", action: #selector(redoPressed)
        )
        configure(deleteButton, symbol: "trash", label: "Delete", action: #selector(deletePressed))
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        copyButton.toolTip = "Copy the current image (⌘C)"
        saveButton.target = self
        saveButton.action = #selector(saveDocument)

        for control in [
            tools, colors, widths, undoButton, redoButton, deleteButton, copyButton, saveButton,
        ] as [NSControl] {
            control.refusesFirstResponder = true
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        let styleRow = Self.row([tools, colors, widths])
        let actionRow = Self.row(
            [
                snapHint, hiddenNote, spacer, undoButton, redoButton, deleteButton, copyButton,
                saveButton,
            ])
        let bar = NSStackView(views: [styleRow, actionRow])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        for row in [styleRow, actionRow] {
            row.widthAnchor.constraint(
                equalTo: bar.widthAnchor, constant: -(bar.edgeInsets.left + bar.edgeInsets.right)
            ).isActive = true
        }

        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .underPageBackgroundColor
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = canvas

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
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
    }

    private static func swatch(_ color: Palette) -> NSImage {
        NSImage(size: CGSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(cgColor: color.rgba.cgColor)?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    /// Opens at the capture's size in points, shrunk to fit 90% of the screen; tall captures
    /// scroll.
    private func sizeToFit(_ window: NSWindow) {
        let visible =
            (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = CGFloat(model.document.scale)
        let rendered = max(canvas.renderedSize.width, 1)
        let width = min(max(rendered / scale, Self.minimumWidth), visible.width * 0.9)
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

    public func windowDidResize(_ notification: Notification) { fitWidth() }

    /// Brings the toolbar, title and note in line with the model.
    private func update() {
        tools.selectedSegment = Tool.allCases.firstIndex(of: model.tool) ?? 0
        colors.selectedSegment = Palette.allCases.firstIndex(of: model.color) ?? 0
        widths.selectedSegment = StrokeWidth.allCases.firstIndex(of: model.width) ?? 0
        hiddenNote.stringValue = model.hiddenNote(map: canvas.base.map)
        snapHint.stringValue = model.tool == .cut || model.tool == .crop ? Self.snapHint : ""

        undoButton.isEnabled = model.canUndo
        undoButton.toolTip = model.canUndo ? "Undo (⌘Z)" : "Nothing to undo"
        redoButton.isEnabled = model.canRedo
        redoButton.toolTip = model.canRedo ? "Redo (⇧⌘Z)" : "Nothing to redo"
        deleteButton.isEnabled = model.canDelete
        deleteButton.toolTip =
            model.canDelete
            ? "Delete the \(model.selection == nil ? "crop" : "selection") (⌫)"
            : "Select an annotation, seam or crop to delete"
        saveButton.isEnabled = model.isDirty
        saveButton.toolTip = model.isDirty ? "Save (⌘S)" : "No unsaved changes"
        window?.isDocumentEdited = model.isDirty
        fitWidth()  // a column cut changes the rendered width
    }

    // MARK: Actions

    @objc private func toolChosen() {
        canvas.endText()
        model.tool = Tool.allCases[tools.selectedSegment]
    }

    @objc private func colorChosen() {
        model.setColor(Palette.allCases[colors.selectedSegment])
    }

    @objc private func widthChosen() {
        model.setWidth(StrokeWidth.allCases[widths.selectedSegment])
    }

    @objc private func undoPressed() { undo() }
    @objc private func redoPressed() { redo() }

    @objc private func deletePressed() {
        canvas.endText()
        model.deleteSelection()
    }

    @objc func copyPressed() {
        canvas.endText()
        let original = model.original
        let document = model.document
        copy {
            let image = Renderer.render(original, edits: document).image
            return try PNGCodec.encode(image, scale: document.scale)
        }
    }

    /// ⌘S: with nothing unsaved there is nothing to write, so an unedited capture stays one file.
    @objc func saveDocument() {
        guard model.isDirty else { return }
        _ = writeDocument()
    }

    func undo() {
        canvas.endText()
        model.undo()
    }

    func redo() {
        canvas.endText()
        model.redo()
    }

    /// Writes the primary and master; false (after telling the user) when that failed.
    private func writeDocument() -> Bool {
        canvas.endText()
        do {
            try save(model.document)
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
        canvas.endText()
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

/// Routes the editor's shortcuts itself: an accessory app has no menu bar to carry them.
@MainActor
final class EditorWindow: NSWindow {
    weak var editor: EditorWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Save and close work everywhere, including while a text field is being edited.
        switch (flags, key) {
        case ([.command], "s"):
            editor?.saveDocument()
            return true
        case ([.command], "w"):
            performClose(nil)
            return true
        default:
            break
        }
        // Without a main menu nothing translates the edit shortcuts, so a field being edited
        // gets them here.
        if firstResponder is NSTextView {
            let action: Selector?
            switch (flags, key) {
            case ([.command], "x"): action = #selector(NSText.cut(_:))
            case ([.command], "c"): action = #selector(NSText.copy(_:))
            case ([.command], "v"): action = #selector(NSText.paste(_:))
            case ([.command], "a"): action = #selector(NSText.selectAll(_:))
            case ([.command], "z"): action = Selector(("undo:"))
            case ([.command, .shift], "z"): action = Selector(("redo:"))
            default: action = nil
            }
            if let action { return NSApp.sendAction(action, to: nil, from: self) }
            return super.performKeyEquivalent(with: event)
        }
        switch (flags, key) {
        case ([.command], "z"):
            editor?.undo()
        case ([.command, .shift], "z"):
            editor?.redo()
        case ([.command], "c"):
            editor?.copyPressed()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
