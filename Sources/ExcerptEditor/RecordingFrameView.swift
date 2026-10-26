import AppKit
import ExcerptCore

/// The rendered frame, fitted to the view, with every blur's outline over it: drawn under the
/// blur tool, selected with a click, the selection's item bar above it. Blur rects are master
/// pixels with a top-left origin, as `BlurRenderer` takes them for the master's frame; the view
/// is flipped, so view and master share that orientation and differ only by the fit's offset
/// and zoom.
@MainActor
final class RecordingFrameView: NSView {
    static let gutter: CGFloat = 12

    let pixelSize: CGSize
    /// The frame at the playhead as the primary renders it; nil when it couldn't be decoded.
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

    /// Where the frame is drawn: the master's aspect fitted inside the gutter.
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

    /// View points per master pixel.
    private var zoom: CGFloat { imageRect.width / max(pixelSize.width, 1) }

    /// A rect of master pixels where it is drawn in the view.
    func viewRect(_ pixels: CGRect) -> CGRect {
        let image = imageRect
        return CGRect(
            x: image.minX + pixels.minX * zoom, y: image.minY + pixels.minY * zoom,
            width: pixels.width * zoom, height: pixels.height * zoom)
    }

    /// A rect of the view as master pixels.
    func pixelRect(_ view: CGRect) -> CGRect {
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
