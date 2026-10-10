import AppKit

public enum SelectionMode {
    case area
    case window(windows: [CapturableWindow])
}

public enum SelectionResult {
    case area(DisplayStill, pixelRect: CGRect)
    case window(CapturableWindow)
    case cancelled
}

/// One borderless window per display showing that display's frozen still. Area mode drags a
/// rectangle (Space held moves it); window mode highlights the window under the cursor. Esc
/// cancels.
@MainActor
public final class SelectionOverlay {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<SelectionResult, Never>?

    public init() {}

    public func run(mode: SelectionMode, stills: [DisplayStill]) async -> SelectionResult {
        guard !stills.isEmpty else { return .cancelled }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for still in stills {
                let window = OverlayWindow(still: still, mode: mode) { [weak self] result in
                    self?.finish(result)
                }
                windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            let mouse = NSEvent.mouseLocation
            (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ result: SelectionResult) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        continuation.resume(returning: result)
    }
}

final class OverlayWindow: NSWindow {
    init(still: DisplayStill, mode: SelectionMode, finish: @escaping (SelectionResult) -> Void) {
        super.init(
            contentRect: still.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(still.frame, display: false)
        isReleasedWhenClosed = false
        let view = OverlayView(still: still, mode: mode, finish: finish)
        contentView = view
        initialFirstResponder = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    private let still: DisplayStill
    private let mode: SelectionMode
    private let finish: (SelectionResult) -> Void
    private let image: NSImage
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var cursor: CGPoint?
    private var moving = false
    private var hovered: CapturableWindow?

    init(still: DisplayStill, mode: SelectionMode, finish: @escaping (SelectionResult) -> Void) {
        self.still = still
        self.mode = mode
        self.finish = finish
        self.image = NSImage(cgImage: still.image, size: still.frame.size)
        super.init(frame: CGRect(origin: .zero, size: still.frame.size))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // top-left, matching the still's pixel rows
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let anchor, let current else { return nil }
        return SelectionMath.rect(from: anchor, to: current)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if case .window(let list) = mode {
            let global = NSEvent.mouseLocation
            hovered = list.first { $0.frame.contains(global) }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .window = mode {
            if let hovered { finish(.window(hovered)) }
            return
        }
        anchor = point
        current = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if moving, let anchor, let current {
            let dx = point.x - current.x
            let dy = point.y - current.y
            self.anchor = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        }
        current = point
        cursor = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard case .area = mode else { return }
        guard let selection, SelectionMath.isCapturable(selection) else {
            finish(.cancelled)  // a click or a sliver
            return
        }
        let pixels = DisplayGeometry.pixelRect(
            forLocalPoints: selection, scale: still.scale,
            imageSize: CGSize(width: still.image.width, height: still.image.height))
        finish(.area(still, pixelRect: pixels))
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: finish(.cancelled)  // Esc
        case 49: moving = true  // Space
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == 49 { moving = false }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        image.draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil
        )
        let highlight: CGRect? = {
            switch mode {
            case .area: return selection
            case .window:
                guard let hovered, let window = self.window else { return nil }
                let local = window.convertFromScreen(hovered.frame)
                return CGRect(
                    x: local.minX, y: bounds.height - local.maxY, width: local.width,
                    height: local.height)
            }
        }()

        let dim = NSBezierPath(rect: bounds)
        if let highlight {
            dim.append(NSBezierPath(rect: highlight))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        if let highlight {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: highlight.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            if case .area = mode { drawSizeLabel(for: highlight) }
        }
        if case .area = mode, let cursor {
            if selection == nil { drawCrosshair(at: cursor) }
            drawLoupe(at: cursor)
        }
    }

    private func drawCrosshair(at point: CGPoint) {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        path.move(to: CGPoint(x: point.x, y: 0))
        path.line(to: CGPoint(x: point.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: point.y))
        path.line(to: CGPoint(x: bounds.width, y: point.y))
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(
            x: rect.maxX - size.width - 8, y: min(rect.maxY + 6, bounds.height - size.height - 6))
        let pill = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    /// 8× magnification of the frozen pixels around the cursor, beside it.
    private func drawLoupe(at point: CGPoint) {
        let diameter: CGFloat = 120
        let sourcePoints: CGFloat = diameter / 8
        let source = DisplayGeometry.pixelRect(
            forLocalPoints: CGRect(
                x: point.x - sourcePoints / 2, y: point.y - sourcePoints / 2, width: sourcePoints,
                height: sourcePoints),
            scale: still.scale,
            imageSize: CGSize(width: still.image.width, height: still.image.height))
        guard let crop = still.image.cropping(to: source) else { return }
        var frame = CGRect(x: point.x + 20, y: point.y + 20, width: diameter, height: diameter)
        if frame.maxX > bounds.width { frame.origin.x = point.x - 20 - diameter }
        if frame.maxY > bounds.height { frame.origin.y = point.y - 20 - diameter }
        NSGraphicsContext.saveGraphicsState()
        let circle = NSBezierPath(ovalIn: frame)
        circle.addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: frame.size).draw(
            in: frame, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        circle.lineWidth = 2
        circle.stroke()
    }
}
