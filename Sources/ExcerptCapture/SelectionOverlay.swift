import AppKit

public enum SelectionMode {
    case area
    /// An area that stays on screen after the drag until Return, Enter or the start button
    /// confirms it, or a new drag replaces it: the region a scrolling capture follows. It opens
    /// on `previous`, the last scrolling capture's region, already waiting to be started.
    case scrollingArea(previous: ScrollRegion?)
    case window(windows: [CapturableWindow])

    /// Modes that drag a rectangle.
    var isArea: Bool {
        switch self {
        case .area, .scrollingArea: true
        case .window: false
        }
    }
}

public enum SelectionResult {
    case area(DisplayStill, pixelRect: CGRect)
    /// Scrolling-area mode, started by the user scrolling over the selection: they scroll.
    case scrolledArea(DisplayStill, pixelRect: CGRect)
    case window(CapturableWindow)
    case cancelled
}

/// One borderless window per display showing that display's frozen still. Area mode drags a
/// rectangle (Space held moves it); scrolling-area mode keeps the rectangle until Return, Enter
/// or its start button; window mode highlights the window under the cursor. Esc cancels.
///
/// `cover` puts the windows up clear before the stills exist, so a press made while they are
/// taken lands on the overlay instead of the window beneath, where it would activate that app and
/// cancel the capture; `run` fills them and honours that press.
@MainActor
public final class SelectionOverlay {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<SelectionResult, Never>?
    private var observers: [NSObjectProtocol] = []
    /// The outcome when the overlay finished before `run` waited on it.
    private var result: SelectionResult?

    public init() {}

    /// Shows the overlay clear on every display, catching the pointer; nothing once it
    /// is up or finished.
    public func cover() {
        guard windows.isEmpty, result == nil else { return }
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let window = OverlayWindow(
                displayID: displayID, frame: screen.frame,
                finish: { [weak self] result in self?.finish(result) },
                beginDrag: { [weak self] origin in
                    self?.clearSelections(except: origin) ?? false
                })
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSCursor.crosshair.push()
        // Losing activation (Esc would never arrive) or a display change (the stills no
        // longer match the screens) must not strand the full-screen overlay.
        for name in [
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(.cancelled) }
                })
        }
    }

    /// Fills the overlay with `stills`, covering first if `cover` wasn't called, and waits for
    /// the selection.
    public func run(mode: SelectionMode, stills: [DisplayStill]) async -> SelectionResult {
        guard !stills.isEmpty else {
            close()
            return .cancelled
        }
        cover()
        if let result { return result }
        // Activated only now, so the stills show the frontmost app as it was.
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for window in windows {
                if let still = stills.first(where: { $0.displayID == window.displayID }) {
                    window.present(still: still, mode: mode)
                } else {
                    window.orderOut(nil)
                }
                if self.continuation == nil { break }  // a press made while covering finished it
            }
        }
    }

    /// Takes the overlay down, cancelled once it hasn't finished.
    public func close() {
        finish(.cancelled)
        dismiss()
    }

    /// Takes down windows a capture started by scrolling left up: it keeps them until its first
    /// frame, so wheel events land on the frozen screen rather than moving the page first.
    public func dismiss() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    /// One live selection: a drag starting on one display clears the others' settled rectangles.
    /// True when one of them was settled, so the press counts as clearing it.
    private func clearSelections(except origin: OverlayView) -> Bool {
        var cleared = false
        for window in windows where window.overlayView !== origin {
            cleared = window.overlayView.clearSettledSelection() || cleared
        }
        return cleared
    }

    private func finish(_ result: SelectionResult) {
        guard self.result == nil else { return }
        self.result = result
        if !windows.isEmpty { NSCursor.pop() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if case .scrolledArea = result {} else { dismiss() }
        continuation?.resume(returning: result)
        continuation = nil
    }
}

final class OverlayWindow: NSWindow {
    let displayID: CGDirectDisplayID
    let overlayView: OverlayView

    init(
        displayID: CGDirectDisplayID, frame: CGRect,
        finish: @escaping (SelectionResult) -> Void,
        beginDrag: @escaping (OverlayView) -> Bool
    ) {
        self.displayID = displayID
        overlayView = OverlayView(size: frame.size, finish: finish, beginDrag: beginDrag)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        // Clear until the still arrives; set explicitly, so the clear window still takes clicks.
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(frame, display: false)
        isReleasedWhenClosed = false
        contentView = overlayView
        initialFirstResponder = overlayView
        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }

    /// Shows `still` in `mode`, on the display's frame as the still saw it.
    func present(still: DisplayStill, mode: SelectionMode) {
        setFrame(still.frame, display: false)
        overlayView.present(still: still, mode: mode)
    }
}

final class OverlayView: NSView {
    /// Nil while covering, before the still arrives.
    private var still: DisplayStill?
    private var mode: SelectionMode?
    private var image: NSImage?
    private let finish: (SelectionResult) -> Void
    private let beginDrag: (OverlayView) -> Bool
    /// A press made while covering, in global points: window mode takes the window under it.
    private var earlyPress: CGPoint?
    /// That press was released while covering too, so area modes end its drag once presented.
    private var releasedEarly = false
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var cursor: CGPoint?
    private var moving = false
    private var hovered: CapturableWindow?
    /// Scrolling-area mode: the drag is over and the selection waits to be started.
    private var settled = false
    /// The press that began the current drag cleared a settled selection, so a click ending it
    /// clears rather than cancels.
    private var pressClearedSelection = false
    static let startTitle = "Start Scrolling Capture  ↩"
    static let startButtonSize = CGSize(width: 220, height: 28)

    init(
        size: CGSize, finish: @escaping (SelectionResult) -> Void,
        beginDrag: @escaping (OverlayView) -> Bool
    ) {
        self.finish = finish
        self.beginDrag = beginDrag
        super.init(frame: CGRect(origin: .zero, size: size))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `still` in `mode`, then settles a press made while covering: window mode takes the
    /// window it landed on; area modes end its drag if it was already released.
    func present(still: DisplayStill, mode: SelectionMode) {
        self.still = still
        self.mode = mode
        image = NSImage(cgImage: still.image, size: still.frame.size)
        needsDisplay = true
        if case .window(let list) = mode {
            if let earlyPress {
                finish(
                    list.first { $0.frame.contains(earlyPress) }.map { .window($0) } ?? .cancelled)
                return
            }
            updateHover()  // highlight appears before the mouse moves
        } else if releasedEarly {
            endDrag()
        } else if earlyPress == nil, case .scrollingArea(let previous?) = mode {
            settle(previous, on: still)
        }
    }

    /// Shows the last scrolling region waiting to be started, when it was on this display and
    /// still fits on it.
    private func settle(_ previous: ScrollRegion, on still: DisplayStill) {
        guard previous.displayID == still.displayID else { return }
        let rect = previous.localPoints.intersection(bounds)
        guard !rect.isNull, SelectionMath.isCapturable(rect) else { return }
        anchor = rect.origin
        current = CGPoint(x: rect.maxX, y: rect.maxY)
        settled = true
    }

    override var isFlipped: Bool { true }  // top-left, matching the still's pixel rows
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: CGRect? {
        guard let anchor, let current else { return nil }
        // Space-move can push the drag fully off the display, leaving nothing to draw or crop.
        let rect = SelectionMath.rect(from: anchor, to: current, within: bounds)
        return rect.isNull || rect.isEmpty ? nil : rect
    }

    /// The window under the global cursor; the one lookup behind both the highlight and a click.
    private func updateHover() {
        guard case .window(let list) = mode else { return }
        let global = NSEvent.mouseLocation
        hovered = list.first { $0.frame.contains(global) }
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if still == nil { earlyPress = NSEvent.mouseLocation }  // tracked as a drag meanwhile
        if case .window = mode {
            updateHover()
            finish(hovered.map { .window($0) } ?? .cancelled)  // a click on nothing cancels
            return
        }
        if settled, let button = startButton, button.contains(point) {
            confirm()
            return
        }
        let clearedOther = beginDrag(self)
        pressClearedSelection = settled || clearedOther
        settled = false
        anchor = point
        current = point
        needsDisplay = true
    }

    /// Clears a settled selection; reports whether there was one.
    func clearSettledSelection() -> Bool {
        guard settled else { return false }
        clearSelection()
        return true
    }

    /// Drops the selection and any settled state; the overlay stays up.
    func clearSelection() {
        settled = false
        anchor = nil
        current = nil
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
        guard still != nil else {
            releasedEarly = earlyPress != nil
            return
        }
        endDrag()
    }

    /// Releases the drag: a capturable selection confirms, or settles in scrolling-area mode.
    private func endDrag() {
        guard mode?.isArea == true, !settled else { return }
        guard let selection, SelectionMath.isCapturable(selection) else {
            if case .scrollingArea = mode, pressClearedSelection {
                clearSelection()  // a click on a settled selection clears it
            } else {
                finish(.cancelled)  // a click or a sliver with nothing settled
            }
            return
        }
        if case .scrollingArea = mode {
            settled = true
            needsDisplay = true
        } else {
            confirm()
        }
    }

    /// Finishes with the selection cropped from the still.
    private func confirm(scrolled: Bool = false) {
        guard let still, let selection, SelectionMath.isCapturable(selection) else { return }
        let pixels = DisplayGeometry.pixelRect(
            forLocalPoints: selection, scale: still.scale,
            imageSize: CGSize(width: still.image.width, height: still.image.height))
        finish(scrolled ? .scrolledArea(still, pixelRect: pixels) : .area(still, pixelRect: pixels))
    }

    /// A wheel over a settled scrolling selection starts the capture with the user scrolling.
    /// This first event lands on the overlay, so the page hasn't moved when the first frame is
    /// taken. Fingers resting on the trackpad send wheel events that move nothing; those aren't
    /// scrolling.
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0,
            settled, case .scrollingArea = mode, let selection,
            selection.contains(convert(event.locationInWindow, from: nil))
        else { return }
        confirm(scrolled: true)
    }

    /// The screen's visible frame (clear of menu bar and Dock) in this view's top-left points:
    /// the space the HUD is laid out in, so the button sits where the HUD will.
    private var visibleBounds: CGRect {
        guard let still, let visible = window?.screen?.visibleFrame else { return bounds }
        let local = DisplayGeometry.localPoints(forAppKitRect: visible, displayFrame: still.frame)
        let clipped = local.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? bounds : clipped
    }

    /// The start button's frame while a scrolling-area selection waits; nil otherwise.
    private var startButton: CGRect? {
        guard case .scrollingArea = mode, settled, let selection else { return nil }
        return SelectionMath.startButtonFrame(
            for: selection, size: Self.startButtonSize, in: visibleBounds)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: finish(.cancelled)  // Esc
        case 49: moving = true  // Space
        case 36, 76: if settled { confirm() }  // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == 49 { moving = false }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let still, let image, let mode else { return }  // clear while covering
        image.draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil
        )
        let highlight: CGRect? = {
            switch mode {
            case .area, .scrollingArea: return selection
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
            if mode.isArea { drawSizeLabel(for: highlight, avoiding: startButton) }
        }
        if let startButton { drawStartButton(in: startButton) }
        if mode.isArea, !settled, let cursor {
            if selection == nil { drawCrosshair(at: cursor) }
            drawLoupe(at: cursor, in: still)
        }
    }

    private func drawStartButton(in frame: CGRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
            .fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = Self.startTitle as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attributes)
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

    private func drawSizeLabel(for rect: CGRect, avoiding button: CGRect?) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        var origin = CGPoint(
            x: rect.maxX - size.width - 8, y: min(rect.maxY + 6, bounds.height - size.height - 6))
        var pill = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        if let button, pill.intersects(button) {
            // Above the selection instead, else inside its top edge.
            origin.y = rect.minY - 6 - size.height
            if origin.y < 3 { origin.y = rect.minY + 6 }
            pill = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        text.draw(at: origin, withAttributes: attributes)
    }

    /// 8× magnification of the frozen pixels around the cursor, beside it.
    private func drawLoupe(at point: CGPoint, in still: DisplayStill) {
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
