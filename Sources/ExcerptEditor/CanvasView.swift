import AppKit
import ExcerptCore

/// Draws the capture through Core: the cached base render (blur, crop, cuts) as an image, then
/// the annotations through `AnnotationRenderer` and the `Border` on every repaint, then the
/// editor's own chrome
/// (selection, handles, a drag in progress). Input goes to the model in rendered pixels.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    let model: EditorModel
    /// Called after anything the window shows might have changed.
    var onChange: () -> Void = {}
    /// View points per rendered pixel.
    var zoom: CGFloat = 1 {
        didSet {
            guard zoom > 0 else {
                zoom = oldValue
                return
            }
            model.viewScale = Double(zoom)
            resize()
        }
    }

    /// The cut-band shade, on the pending band and on the collapse that follows its release.
    private static let bandShade = NSColor.systemRed.withAlphaComponent(0.25)

    private static let accent = NSColor.controlAccentColor.cgColor

    private(set) var base: RenderResult
    private var baseDocument: EditDocument
    /// Takes the typing: input, caret and selection only. Its glyphs are transparent, since the
    /// canvas draws the text being typed through Core like any other annotation.
    private var textView: NSTextView?
    /// Floats beside the item being typed or selected, with that item's options. It lives over
    /// the scroll view rather than in the canvas, so on a capture narrower than the bar it can
    /// still be seen and clicked in full.
    private let itemBar = ItemBar()
    /// The text view's undo, separate from the window's, so a removed text view leaves nothing
    /// for ⌘Z to undo; a new one for each text typed.
    private var typingUndo = UndoManager()

    init(model: EditorModel) {
        self.model = model
        baseDocument = model.baseDocument
        base = Renderer.renderBase(model.original, edits: baseDocument)
        super.init(frame: .zero)
        model.onChange = { [weak self] in self?.refresh() }
        itemBar.onColor = { [weak self] in self?.model.setColor($0) }
        itemBar.onSize = { [weak self] in self?.model.setWidth($0) }
        itemBar.onBackground = { [weak self] in self?.model.setBackground($0) }
        itemBar.onClosed = { [weak self] in self?.model.setClosed($0) }
        itemBar.onFill = { [weak self] in self?.model.setFill($0) }
        itemBar.onMove = { [weak self] in self?.model.moveStep(earlier: $0) }
        itemBar.onDelete = { [weak self] in self?.deleteItem() }
        itemBar.isHidden = true
        resize()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Hosts the item bar over the scroll view, and moves it with the scroll.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            itemBar.removeFromSuperview()
            return
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification,
                object: clip)
        }
        placeItemBar()
    }

    @objc private func clipScrolled() { placeItemBar() }

    /// The view the item bar sits in: beside the scroll view when there is one.
    private var barHost: NSView { enclosingScrollView?.superview ?? self }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var renderedSize: CGSize { CGSize(width: base.image.width, height: base.image.height) }

    /// Re-renders the base only when what it depends on changed, then repaints.
    func refresh() {
        let wanted = model.baseDocument
        if wanted != baseDocument {
            baseDocument = wanted
            base = Renderer.renderBase(model.original, edits: wanted)
            resize()
        }
        needsDisplay = true
        syncTextView()
        placeItemBar()
        onChange()
    }

    private func resize() {
        setFrameSize(
            CGSize(width: renderedSize.width * zoom, height: renderedSize.height * zoom))
        needsDisplay = true
        syncTextView()
        placeItemBar()
    }

    /// What the item bar sits beside, in rendered pixels: the text being typed, the selection,
    /// or the crop under the crop tool; nil during a drag.
    private var barTarget: CGRect? {
        guard model.drag == nil else { return nil }
        let map = base.map
        let scale = model.document.scale
        if let typing = model.typing {
            let bounds = AnnotationGeometry.bounds(of: typing, scale: scale)
            return CGRect(origin: map.point(bounds.origin, bias: .after), size: bounds.size)
        }
        if let building = model.building,
            let annotation = model.document.annotations.first(where: { $0.id == building.id })
        {
            return map.rect(AnnotationGeometry.bounds(of: annotation, scale: scale))
        }
        switch model.selection {
        case .annotation(let id):
            guard let annotation = model.document.annotations.first(where: { $0.id == id })
            else { return nil }
            return map.rect(AnnotationGeometry.bounds(of: annotation, scale: scale))
        case .seam(let axis, let band):
            return map.seams(axis).first(where: { $0.band == band }).map(gapRect)
        case nil:
            guard model.tool == .crop, let crop = model.document.crop else { return nil }
            return map.rect(crop.cgRect)
        }
    }

    var itemBarView: NSView { itemBar }

    /// The bar's frame in this view's points while it shows.
    var itemBarFrame: CGRect? {
        itemBar.isHidden || itemBar.superview == nil
            ? nil : convert(itemBar.frame, from: itemBar.superview)
    }

    /// Above the target, left-aligned with it; below it when there is no room above; kept
    /// within what the scroll view shows (the canvas itself when there is no scroll view).
    private func placeItemBar() {
        let host = barHost
        if itemBar.superview !== host { host.addSubview(itemBar) }
        guard let options = model.itemOptions, let target = barTarget else {
            itemBar.isHidden = true
            return
        }
        itemBar.show(options)
        let size = itemBar.frame.size
        let area =
            enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView) }
            ?? bounds
        let rect = viewRect(target)
        let gap: CGFloat = 6
        let above = rect.minY - size.height - gap
        let y =
            above >= area.minY + 4
            ? above : min(rect.maxY + gap, area.maxY - size.height - 4)
        let x = min(max(rect.minX, area.minX + 4), max(area.minX + 4, area.maxX - size.width - 4))
        let frame = CGRect(origin: CGPoint(x: x, y: max(area.minY + 4, y)), size: size)
        itemBar.frame = host.convert(frame, from: self)
        itemBar.isHidden = false
    }

    /// The bar's delete: drops the text being typed, else deletes the selection.
    func deleteItem() {
        if model.typing != nil {
            dropTextView()
            model.deleteTyping()
            window?.makeFirstResponder(self)
        } else {
            model.deleteSelection()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = base.image.height
        context.saveGState()
        context.scaleBy(x: zoom, y: zoom)
        context.interpolationQuality = zoom < 1 ? .high : .none

        // The base, cut to the dirty region so a tall capture draws only what is visible.
        let bounds = CGRect(origin: .zero, size: renderedSize)
        let visible = CGRect(
            x: dirtyRect.minX / zoom, y: dirtyRect.minY / zoom, width: dirtyRect.width / zoom,
            height: dirtyRect.height / zoom
        ).integral.intersection(bounds)
        if !visible.isEmpty, let piece = base.image.cropping(to: visible) {
            context.saveGState()
            context.translateBy(x: 0, y: visible.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(
                piece,
                in: CGRect(x: visible.minX, y: 0, width: visible.width, height: visible.height))
            context.restoreGState()
        }

        // Annotations through Core, in its bottom-left canvas space.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(
            model.displayDocument.annotations, map: base.map, scale: model.document.scale,
            in: context, canvasHeight: height)
        model.document.border?.draw(
            in: context, width: base.image.width, height: height, scale: model.document.scale)
        context.restoreGState()

        drawChrome(in: context)
        context.restoreGState()
    }

    private func drawChrome(in context: CGContext) {
        let map = base.map
        let line = 1 / zoom
        let accent = Self.accent
        context.setLineWidth(2 * line)

        if model.tool == .crop, let crop = model.document.crop, let rect = map.rect(crop.cgRect) {
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: renderedSize))
            path.addRect(rect)
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 0.45))
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.stroke(rect)
        }

        switch model.selection {
        case .annotation(let id) where model.typing == nil:
            if let annotation = model.document.annotations.first(where: { $0.id == id }),
                let rect = map.rect(
                    AnnotationGeometry.bounds(of: annotation, scale: model.document.scale))
            {
                context.setStrokeColor(accent)
                strokeDashed(rect.insetBy(dx: -3 * line, dy: -3 * line), in: context)
            }
        case .seam(let axis, let band):
            if let seam = map.seams(axis).first(where: { $0.band == band }) {
                drawSeamSelection(seam, in: context)
            }
        case .annotation, nil:
            break
        }

        switch model.pending {
        case .cut(let cut)?:
            context.setFillColor(Self.bandShade.cgColor)
            context.fill(bandRect(cut))
        case .region(let region)?:
            if let rect = map.rect(region) {
                context.setStrokeColor(accent)
                strokeDashed(rect, in: context)
            }
        case .edge(let seam, _, let position)?:
            let point = map.point(
                seam.axis == .horizontal
                    ? CGPoint(x: map.crop.x, y: position) : CGPoint(x: position, y: map.crop.y))
            context.setStrokeColor(accent)
            if seam.axis == .horizontal {
                context.strokeLineSegments(between: [
                    CGPoint(x: 0, y: point.y), CGPoint(x: renderedSize.width, y: point.y),
                ])
            } else {
                context.strokeLineSegments(between: [
                    CGPoint(x: point.x, y: 0), CGPoint(x: point.x, y: renderedSize.height),
                ])
            }
        case nil:
            break
        }

        drawPathHandles(in: context)
    }

    private func strokeDashed(_ rect: CGRect, in context: CGContext) {
        let line = 1 / zoom
        context.setLineDash(phase: 0, lengths: [4 * line, 3 * line])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
    }

    /// The seam's gap outlined, with a round handle on each edge.
    private func drawSeamSelection(_ seam: Seam, in context: CGContext) {
        let line = 1 / zoom
        let gap = gapRect(seam)
        context.setStrokeColor(Self.accent)
        context.stroke(gap)
        let handles: [CGPoint] =
            seam.axis == .horizontal
            ? [CGPoint(x: gap.midX, y: gap.minY), CGPoint(x: gap.midX, y: gap.maxY)]
            : [CGPoint(x: gap.minX, y: gap.midY), CGPoint(x: gap.maxX, y: gap.midY)]
        for handle in handles { drawKnob(at: handle, radius: 5 * line, in: context) }
    }

    /// A white disc ringed in the accent: a draggable handle.
    private func drawKnob(at centre: CGPoint, radius: CGFloat, in context: CGContext) {
        let knob = CGRect(
            x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: knob)
        context.strokeEllipse(in: knob)
    }

    /// The vertices of the path being built, or of the selected path, as handles; while
    /// building, the first vertex is larger once a click on it would close the path.
    private func drawPathHandles(in context: CGContext) {
        let id: Int?
        if let building = model.building {
            id = building.id
        } else if case .annotation(let selected)? = model.selection, model.typing == nil {
            id = selected
        } else {
            id = nil
        }
        guard let id, let note = model.document.annotations.first(where: { $0.id == id }),
            case .path(let points, _, _) = note.shape
        else { return }
        let line = 1 / zoom
        context.setStrokeColor(Self.accent)
        context.setLineWidth(2 * line)
        for (i, vertex) in points.enumerated() {
            let closes = model.building != nil && i == 0 && points.count >= 3
            drawKnob(at: base.map.point(vertex), radius: (closes ? 7 : 4) * line, in: context)
        }
    }

    /// A seam's gap in rendered pixels, across the whole image.
    func gapRect(_ seam: Seam) -> CGRect {
        seam.axis == .horizontal
            ? CGRect(
                x: 0, y: seam.gap.lowerBound, width: Int(renderedSize.width), height: seam.gap.count
            )
            : CGRect(
                x: seam.gap.lowerBound, y: 0, width: seam.gap.count,
                height: Int(renderedSize.height))
    }

    /// The rendered rect a pending cut would remove, across the whole image.
    func bandRect(_ cut: Cut) -> CGRect {
        let map = base.map
        if cut.axis == .horizontal {
            let top = map.rows.place(Double(cut.lower - map.crop.y), bias: .after)
            let bottom = map.rows.place(Double(cut.upper - map.crop.y), bias: .before)
            return CGRect(
                x: 0, y: top, width: Double(renderedSize.width), height: max(0, bottom - top))
        }
        let left = map.columns.place(Double(cut.lower - map.crop.x), bias: .after)
        let right = map.columns.place(Double(cut.upper - map.crop.x), bias: .before)
        return CGRect(
            x: left, y: 0, width: max(0, right - left), height: Double(renderedSize.height))
    }

    // MARK: Input

    private func pointer(_ event: NSEvent) -> Pointer {
        let p = convert(event.locationInWindow, from: nil)
        return Pointer(rendered: CGPoint(x: p.x / zoom, y: p.y / zoom), map: base.map)
    }

    /// Rendered pixels to view points.
    private func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom, y: p.y * zoom) }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(
            origin: viewPoint(r.origin),
            size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    private func snap(_ event: NSEvent) -> Bool { !event.modifierFlags.contains(.option) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = pointer(event)
        if model.tool == .text {
            beginText(at: p)
            return
        }
        if model.tool == .select, event.clickCount == 2, model.textID(at: p, map: base.map) != nil {
            beginText(at: p)
            return
        }
        model.mouseDown(
            p, map: base.map, clickCount: event.clickCount,
            option: event.modifierFlags.contains(.option))
    }

    private var tracking: NSTrackingArea?

    /// Tracks the pointer over the visible canvas, for the path being built's last segment.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { model.hover(pointer(event)) }
    override func mouseExited(with event: NSEvent) { model.hover(nil) }

    override func mouseDragged(with event: NSEvent) {
        model.mouseDragged(pointer(event), map: base.map, snap: snap(event))
    }

    override func mouseUp(with event: NSEvent) {
        let pendingCut: Cut?
        if case .cut(let cut)? = model.pending { pendingCut = cut } else { pendingCut = nil }
        let before = pendingCut.map(bandRect)
        model.mouseUp(pointer(event), map: base.map, snap: snap(event))
        if let cut = pendingCut, let before { animateCollapse(of: cut, from: before) }
    }

    /// The shaded band shrinks into its new seam.
    private func animateCollapse(of cut: Cut, from band: CGRect) {
        guard
            let seam = base.map.seams(cut.axis).first(where: { $0.band.contains(cut.lower) })
        else { return }
        let shade = NSView(frame: viewRect(band))
        shade.wantsLayer = true
        shade.layer?.backgroundColor = Self.bandShade.cgColor
        addSubview(shade)
        let target = viewRect(gapRect(seam))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            shade.animator().frame = target
            shade.animator().alphaValue = 0
        } completionHandler: {
            shade.removeFromSuperview()
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let characters = event.charactersIgnoringModifiers,
            characters.count == 1, let tool = Tool(key: characters.first!)
        {
            model.tool = tool
            return
        }
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            model.deleteSelection()
        case 36, 76:  // return, enter
            if model.building != nil { model.finishPath() } else { super.keyDown(with: event) }
        case 53:  // escape
            if model.building != nil { model.dropLastVertex() } else { model.selection = nil }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Text

    func beginText(at p: Pointer) {
        commitInProgress()
        model.beginTyping(at: p, map: base.map)
        typingUndo = UndoManager()
        let view = NSTextView(frame: .zero)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isHorizontallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.string = model.typedString
        view.delegate = self
        addSubview(view)
        textView = view
        syncTextView()
        window?.makeFirstResponder(view)
    }

    /// Lays the text view over the rendered text being typed: the same font and line height at
    /// this zoom, transparent glyphs, and the caret in the ink the render uses.
    private func syncTextView() {
        guard let view = textView, let typing = model.typing,
            case .text(let origin, _, let background) = typing.shape,
            let rect = AnnotationGeometry.textRect(of: typing, scale: model.document.scale)
        else { return }
        let pixelSize =
            AnnotationGeometry.textPixelSize(typing, scale: model.document.scale) * Double(zoom)
        let font = TextLayout.font(pixelSize: pixelSize) as NSFont
        let lineHeight = font.ascender - font.descender + font.leading
        if view.typingAttributes[.font] as? NSFont != font {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.clear, .paragraphStyle: paragraph,
            ]
            view.typingAttributes = attributes
            view.textStorage?.setAttributes(
                attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        }
        let ink = background == true ? typing.color.contrastingInk : typing.color.rgba
        view.insertionPointColor = NSColor(cgColor: ink.cgColor) ?? .textColor
        let topLeft = viewPoint(base.map.point(origin, bias: .after))
        view.frame = CGRect(
            x: topLeft.x, y: topLeft.y,
            width: rect.width * zoom + CGFloat(pixelSize),  // room for the caret past the end
            height: max(rect.height * zoom, lineHeight))
    }

    /// Commits the text being typed and the path being built; safe when neither is.
    func commitInProgress() {
        model.finishPath()
        guard textView != nil else {
            model.endTyping()
            return
        }
        dropTextView()
        model.endTyping()
        window?.makeFirstResponder(self)
    }

    /// Removes the text view without letting its end of editing call back in.
    private func dropTextView() {
        guard let view = textView else { return }
        textView = nil
        view.delegate = nil
        view.removeFromSuperview()
    }

    func textDidChange(_ notification: Notification) {
        model.updateTyping(textView?.string ?? "")
    }

    func textDidEndEditing(_ notification: Notification) { commitInProgress() }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    /// Return and Esc commit; ⌥Return adds a line.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                commitInProgress()
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitInProgress()
            return true
        }
        return false
    }
}
