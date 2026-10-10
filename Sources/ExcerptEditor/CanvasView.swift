import AppKit
import ExcerptCore

/// Draws the capture through Core: the cached base render (blur, crop, cuts) as an image, then
/// the annotations through `AnnotationRenderer` on every repaint, then the editor's own chrome
/// (selection, handles, a drag in progress). Input goes to the model in rendered pixels.
@MainActor
final class CanvasView: NSView, NSTextFieldDelegate {
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
    private var textField: NSTextField?
    private var textTarget: TextTarget?

    init(model: EditorModel) {
        self.model = model
        baseDocument = model.baseDocument
        base = Renderer.renderBase(model.original, edits: baseDocument)
        super.init(frame: .zero)
        model.onChange = { [weak self] in self?.refresh() }
        resize()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
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
        onChange()
    }

    private func resize() {
        setFrameSize(
            CGSize(width: renderedSize.width * zoom, height: renderedSize.height * zoom))
        needsDisplay = true
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
        case .annotation(let id):
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
        case nil:
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
        let radius = 5 * line
        let handles: [CGPoint] =
            seam.axis == .horizontal
            ? [CGPoint(x: gap.midX, y: gap.minY), CGPoint(x: gap.midX, y: gap.maxY)]
            : [CGPoint(x: gap.minX, y: gap.midY), CGPoint(x: gap.maxX, y: gap.midY)]
        for handle in handles {
            let knob = CGRect(
                x: handle.x - radius, y: handle.y - radius, width: 2 * radius, height: 2 * radius)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: knob)
            context.strokeEllipse(in: knob)
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
            beginText(model.textTarget(at: p, map: base.map))
            return
        }
        if model.tool == .select, event.clickCount == 2 {
            let target = model.textTarget(at: p, map: base.map)
            if target.id != nil {
                beginText(target)
                return
            }
        }
        model.mouseDown(p, map: base.map)
    }

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
        case 53:  // escape
            model.selection = nil
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Text

    private func beginText(_ target: TextTarget) {
        endText()
        let map = base.map
        let origin = viewPoint(map.point(target.origin, bias: .after))
        let size = CGFloat(target.width.textPoints * model.document.scale) * zoom
        let field = NSTextField(string: target.string)
        field.font = TextLayout.font(pixelSize: Double(size)) as NSFont
        field.textColor = NSColor(cgColor: target.color.rgba.cgColor)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.85)
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.frame = CGRect(
            x: origin.x, y: origin.y, width: max(240, size * 8),
            height: size * 1.4 * CGFloat(max(1, target.string.components(separatedBy: "\n").count)))
        // The cell insets its text, so the field moves back by that much and the typed text sits
        // where the committed text will be drawn.
        if let inset = field.cell?.titleRect(forBounds: field.bounds).origin {
            field.frame.origin = CGPoint(x: origin.x - inset.x, y: origin.y - inset.y)
        }
        addSubview(field)
        textField = field
        textTarget = target
        model.editingID = target.id
        window?.makeFirstResponder(field)
        onChange()
    }

    /// Commits whatever is typed; safe to call when no text is being edited.
    func endText() {
        guard let field = textField, let target = textTarget else { return }
        textField = nil
        textTarget = nil
        let string = field.stringValue
        field.removeFromSuperview()
        model.editingID = nil
        model.commitText(target, string: string)
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ notification: Notification) { endText() }

    /// Return commits; ⌥Return adds a line.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
        if selector == #selector(NSResponder.insertNewline(_:)),
            NSApp.currentEvent?.modifierFlags.contains(.option) == true
        {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }
}
