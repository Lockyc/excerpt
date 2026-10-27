import AppKit

public enum SelectionMode {
    case area
    /// An area that stays on screen after the drag until Return, Enter or the start button
    /// confirms it, or a new drag replaces it: the region a scrolling capture follows. It opens
    /// on `previous`, the last scrolling capture's region, already waiting to be started.
    case scrollingArea(previous: ScrollRegion?)
    case window(windows: [CapturableWindow])
    /// An area that stays on screen, with a bar of `choices` over it, until one is picked. It
    /// opens on `previous`, the area last picked from the bar.
    case modeBar(previous: ScrollRegion?, choices: [ModeChoice])
    /// The area to record: one that stays on screen until Return, Enter or its Record button
    /// confirms it. A click with no drag selects the area the window under it covers, `F` the
    /// whole display under the pointer. It opens on `previous`, the last recorded area.
    case recordingArea(previous: ScrollRegion?, windows: [CapturableWindow])

    /// Modes that drag a rectangle.
    var isArea: Bool {
        switch self {
        case .area, .scrollingArea, .modeBar, .recordingArea: true
        case .window: false
        }
    }

    /// Modes whose rectangle stays on screen after the drag, to be moved, resized or replaced.
    var settles: Bool {
        switch self {
        case .scrollingArea, .modeBar, .recordingArea: true
        case .area, .window: false
        }
    }

    /// The windows a press can pick, highlighted under the pointer.
    var windows: [CapturableWindow] {
        switch self {
        case .window(let windows), .recordingArea(_, let windows): windows
        case .area, .scrollingArea, .modeBar: []
        }
    }
}

/// One capture mode on the mode bar.
public struct ModeChoice: Sendable {
    public let id: UInt32
    public let title: String
    /// An SF Symbol name.
    public let symbol: String
    /// The mode's hotkey as shown, e.g. `⌘⇧4`; nil when unbound.
    public let shortcut: String?
    /// Runs on the selected area, so is unavailable while nothing is selected.
    public let usesArea: Bool

    public init(id: UInt32, title: String, symbol: String, shortcut: String?, usesArea: Bool) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.usesArea = usesArea
    }
}

public enum SelectionResult {
    case area(DisplayStill, pixelRect: CGRect)
    /// Recording-area mode, confirmed on the area a click on `window` selected, unmoved and
    /// unresized: a window recording. Any other recording area finishes as `area`.
    case windowArea(CapturableWindow, DisplayStill, pixelRect: CGRect)
    /// Scrolling-area mode, started by the user scrolling over the selection: they scroll.
    case scrolledArea(DisplayStill, pixelRect: CGRect)
    case window(CapturableWindow)
    /// A choice from the mode bar that runs on the selected area.
    case chosenArea(id: UInt32, DisplayStill, pixelRect: CGRect)
    /// A choice from the mode bar that ignores the area: the overlay stays up, so the next
    /// `run` presents the same stills in that mode.
    case chosen(id: UInt32)
    case cancelled
}

/// One borderless window per display showing that display's frozen still. Area mode drags a
/// rectangle (Space held moves it); scrolling-area mode keeps the rectangle until Return, Enter
/// or its start button; mode-bar mode keeps it under a bar of capture modes until one is picked;
/// window mode highlights the window under the cursor; recording-area mode keeps the rectangle
/// until Return, Enter or its Record button, and highlights the window a click would select. A
/// rectangle kept on screen moves when dragged from inside and resizes when dragged by an edge or
/// corner. Esc cancels.
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
    /// What `run` waits for before activating Excerpt, which closes the frontmost app's menus:
    /// the window stills, still being taken while the overlay shows.
    public var activatesAfter: (() async -> Void)?

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
                },
                wholeDisplay: { [weak self] in self?.finishWithDisplayUnderPointer() })
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
            // A selection reopened on another display takes the keys and the mode bar there.
            let settled = windows.first(where: \.overlayView.isSettled)
            if let settled { _ = clearSelections(except: settled.overlayView) }
            Task { await activate(keying: settled) }
        }
    }

    /// Activates Excerpt once `activatesAfter` is done, so the stills show the frontmost app as
    /// it was, and gives the keys to `settled`, or else to the display under the pointer.
    private func activate(keying settled: OverlayWindow?) async {
        await activatesAfter?()
        guard continuation != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (settled ?? windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
    }

    /// Ends the waiting `run` cancelled but keeps the overlay up, so the next `run` presents the
    /// same stills in another mode.
    public func interrupt() {
        handOff(.cancelled)
    }

    /// Ends the waiting `run` with `result`, keeping the overlay up for the next.
    private func handOff(_ result: SelectionResult) {
        guard self.result == nil, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }

    /// Runs `body` with the windows out of its way, for an alert they would cover.
    public func aside<T>(_ body: () -> T) -> T {
        let shown = windows.filter(\.isVisible)
        for window in shown { window.orderOut(nil) }
        defer { for window in shown { window.orderFrontRegardless() } }
        return body()
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

    /// One live selection: a drag starting on one display clears the others' settled rectangles
    /// and mode bars. True when one of them was settled, so the press counts as clearing it.
    private func clearSelections(except origin: OverlayView) -> Bool {
        var cleared = false
        for window in windows where window.overlayView !== origin {
            cleared = window.overlayView.clearSettledSelection() || cleared
        }
        return cleared
    }

    /// Finishes with the whole still of the display under the pointer, whichever window has the
    /// keys.
    private func finishWithDisplayUnderPointer() {
        let mouse = NSEvent.mouseLocation
        let shown = windows.filter(\.isVisible)
        (shown.first { $0.frame.contains(mouse) } ?? shown.first { $0.isKeyWindow })?
            .overlayView.finishWithWholeStill()
    }

    private func finish(_ result: SelectionResult) {
        if case .chosen = result { return handOff(result) }
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
        beginDrag: @escaping (OverlayView) -> Bool,
        wholeDisplay: @escaping () -> Void
    ) {
        self.displayID = displayID
        overlayView = OverlayView(
            size: frame.size, finish: finish, beginDrag: beginDrag, wholeDisplay: wholeDisplay)
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
    /// Recording-area mode's `F`: finishes with the display under the pointer, which need not
    /// be this one.
    private let wholeDisplay: () -> Void
    /// A press made while covering, in global points: window mode takes the window under it.
    private var earlyPress: CGPoint?
    /// That press was released while covering too, so area modes end its drag once presented.
    private var releasedEarly = false
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var cursor: CGPoint?
    private var moving = false
    private var hovered: CapturableWindow?
    /// Recording-area mode: the window whose area a click selected, while the selection is
    /// still exactly that area.
    private var clickedWindow: CapturableWindow?
    /// A settling mode's drag is over: the selection waits to be used, moved or resized.
    private var settled = false
    /// The press that began the current drag cleared a settled selection, so a click ending it
    /// clears rather than cancels.
    private var pressClearedSelection = false
    /// A drag moving or resizing the settled selection: the edges it holds (none to move), the
    /// selection when it began, and where the press landed.
    private var reshaping: (grip: SelectionGrip, from: CGRect, press: CGPoint)?
    /// Mode-bar mode with nothing selected: the point the bar sits below, on the display it
    /// shows on; nil on the others.
    private var idlePoint: CGPoint?
    /// The mode-bar choice under the pointer.
    private var hoveredChoice: Int?
    static let startTitle = "Start Scrolling Capture  ↩"
    static let startButtonSize = CGSize(width: 220, height: 28)
    static let recordTitle = "Record  ↩"
    static let recordButtonSize = CGSize(width: 110, height: 28)
    static let choiceSize = CGSize(width: 96, height: 60)
    static let barInset: CGFloat = 6

    init(
        size: CGSize, finish: @escaping (SelectionResult) -> Void,
        beginDrag: @escaping (OverlayView) -> Bool, wholeDisplay: @escaping () -> Void
    ) {
        self.finish = finish
        self.beginDrag = beginDrag
        self.wholeDisplay = wholeDisplay
        super.init(frame: CGRect(origin: .zero, size: size))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `still` in `mode`, then settles a press made while covering: window mode takes the
    /// window it landed on; area modes end its drag if it was already released. Presenting again
    /// after an interrupt starts over, with nothing selected.
    func present(still: DisplayStill, mode: SelectionMode) {
        if self.still != nil {
            earlyPress = nil
            releasedEarly = false
            pressClearedSelection = false
            moving = false
            hovered = nil
            idlePoint = nil
            hoveredChoice = nil
            clearSelection()
        }
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
        } else if earlyPress == nil {
            switch mode {
            case .scrollingArea(let previous?), .modeBar(let previous?, _),
                .recordingArea(let previous?, _):
                settle(previous, on: still)
            default: break
            }
            updateHover()
            let mouse = NSEvent.mouseLocation
            if case .modeBar = mode, !settled, still.frame.contains(mouse), let window {
                idlePoint = convert(window.convertPoint(fromScreen: mouse), from: nil)
            }
        }
    }

    var isSettled: Bool { settled }

    /// Shows the last region waiting to be used, when it was on this display and still fits on
    /// it.
    private func settle(_ previous: ScrollRegion, on still: DisplayStill) {
        guard previous.displayID == still.displayID else { return }
        settle(previous.localPoints)
    }

    /// Makes `rect`, clipped to the display, the settled selection; false when too little of it
    /// is on the display.
    @discardableResult private func settle(_ rect: CGRect) -> Bool {
        let rect = rect.intersection(bounds)
        guard !rect.isNull, SelectionMath.isCapturable(rect) else { return false }
        anchor = rect.origin
        current = CGPoint(x: rect.maxX, y: rect.maxY)
        settled = true
        needsDisplay = true
        return true
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
        hovered = window(at: NSEvent.mouseLocation)
    }

    /// The mode's window at `global`, an AppKit point.
    private func window(at global: CGPoint) -> CapturableWindow? {
        mode?.windows.first { $0.frame.contains(global) }
    }

    /// The area a click would select in recording-area mode: the window under the pointer as
    /// its rect in this view, while nothing is selected or while the pointer is where a press
    /// starts a new selection rather than using the settled one; nil otherwise.
    private var hoveredArea: CGRect? {
        guard case .recordingArea = mode, reshaping == nil, let still, let hovered else {
            return nil
        }
        if anchor != nil {
            guard settled, let cursor,
                SelectionMath.pressStartsNewSelection(
                    at: cursor, settled: selection, startButton: startButton)
            else { return nil }
        }
        guard let pixels = SelectionMath.windowArea(hovered.frame, in: still) else { return nil }
        return DisplayGeometry.localPoints(forPixelRect: pixels, scale: still.scale)
    }

    /// Recording-area mode's click with no drag: the area the window under `press` covers
    /// becomes the selection, settled. False when there is no window there.
    private func selectWindow(at press: CGPoint) -> Bool {
        guard let still,
            let hit = window(
                at: DisplayGeometry.appKitRect(
                    forLocalPoints: CGRect(origin: press, size: .zero), displayFrame: still.frame
                ).origin),
            let pixels = SelectionMath.windowArea(hit.frame, in: still),
            settle(DisplayGeometry.localPoints(forPixelRect: pixels, scale: still.scale))
        else { return false }
        clickedWindow = hit
        return true
    }

    /// Finishes with this display's whole still.
    func finishWithWholeStill() {
        guard let still else { return }
        finish(
            .area(
                still,
                pixelRect: CGRect(x: 0, y: 0, width: still.image.width, height: still.image.height))
        )
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        updateHover()
        hoveredChoice = choiceIndex(at: point)
        updatePointer(at: point)
        needsDisplay = true
    }

    /// Over a settled selection, the pointer shows what a press there does: move, resize, or
    /// start a new selection.
    private func updatePointer(at point: CGPoint) {
        guard mode?.settles == true else { return }
        if hoveredChoice != nil || startButton?.contains(point) == true {
            NSCursor.arrow.set()
        } else if settled, let selection, let grip = SelectionMath.grip(at: point, on: selection) {
            Self.pointer(for: grip).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func pointer(for grip: SelectionGrip) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch grip {
        case []: return .openHand
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        case [.bottom, .right]: position = .bottomRight
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        default: position = .right
        }
        return .frameResize(position: position, directions: .all)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if still == nil { earlyPress = NSEvent.mouseLocation }  // tracked as a drag meanwhile
        if case .window = mode {
            updateHover()
            finish(hovered.map { .window($0) } ?? .cancelled)  // a click on nothing cancels
            return
        }
        if let index = choiceIndex(at: point) {
            choose(choices[index])  // a press on an unavailable one does nothing
            return
        }
        if settled,
            !SelectionMath.pressStartsNewSelection(
                at: point, settled: selection, startButton: startButton)
        {
            // On the start button, or else on one of the selection's grips.
            if let button = startButton, button.contains(point) {
                confirm()
            } else if let selection, let grip = SelectionMath.grip(at: point, on: selection) {
                clickedWindow = nil  // moved or resized, it is an area
                reshaping = (grip, selection, point)
                if grip.isEmpty { NSCursor.closedHand.set() }
                needsDisplay = true
            }
            return
        }
        let clearedOther = beginDrag(self)
        pressClearedSelection = settled || clearedOther
        settled = false
        clickedWindow = nil
        anchor = point
        current = point
        needsDisplay = true
    }

    /// Clears a settled selection and the mode bar; reports whether there was a selection.
    func clearSettledSelection() -> Bool {
        idlePoint = nil
        needsDisplay = true
        guard settled else { return false }
        clearSelection()
        return true
    }

    /// Drops the selection and any settled state; the overlay stays up.
    func clearSelection() {
        settled = false
        clickedWindow = nil
        reshaping = nil
        anchor = nil
        current = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        if let reshaping {
            let rect = SelectionMath.adjust(
                reshaping.from, grip: reshaping.grip,
                by: CGSize(width: point.x - reshaping.press.x, height: point.y - reshaping.press.y),
                within: bounds)
            anchor = rect.origin
            current = CGPoint(x: rect.maxX, y: rect.maxY)
            needsDisplay = true
            return
        }
        if moving, let anchor, let current {
            let dx = point.x - current.x
            let dy = point.y - current.y
            self.anchor = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        }
        current = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard still != nil else {
            releasedEarly = earlyPress != nil
            return
        }
        if let reshaping {
            self.reshaping = nil
            if selection.map(SelectionMath.isCapturable) != true {  // resized to a sliver
                anchor = reshaping.from.origin
                current = CGPoint(x: reshaping.from.maxX, y: reshaping.from.maxY)
            }
            updatePointer(at: convert(event.locationInWindow, from: nil))
            needsDisplay = true
            return
        }
        endDrag()
    }

    /// Releases the drag: a capturable selection confirms, or settles in a settling mode.
    private func endDrag() {
        guard let mode, mode.isArea, !settled else { return }
        guard let selection, SelectionMath.isCapturable(selection) else {
            if case .modeBar = mode {
                // A click leaves nothing selected, with the bar below it.
                let press = anchor
                clearSelection()
                idlePoint = press
            } else if case .recordingArea = mode, let press = anchor, selectWindow(at: press) {
                // A click on a window selects the area it covers, settled.
            } else if pressClearedSelection, mode.settles {
                clearSelection()  // a click on a settled selection clears it
            } else {
                finish(.cancelled)  // a click or a sliver with nothing settled
            }
            return
        }
        if mode.settles {
            settled = true
            idlePoint = nil
            needsDisplay = true
        } else {
            confirm()
        }
    }

    /// The selection in its still's pixels; nil without a capturable one.
    private var selectedPixels: (still: DisplayStill, rect: CGRect)? {
        guard let still, let selection, SelectionMath.isCapturable(selection) else { return nil }
        return (
            still,
            DisplayGeometry.pixelRect(
                forLocalPoints: selection, scale: still.scale,
                imageSize: CGSize(width: still.image.width, height: still.image.height))
        )
    }

    /// Finishes with the selection cropped from the still.
    private func confirm(scrolled: Bool = false) {
        guard let picked = selectedPixels else { return }
        if let clickedWindow {
            return finish(.windowArea(clickedWindow, picked.still, pixelRect: picked.rect))
        }
        finish(
            scrolled
                ? .scrolledArea(picked.still, pixelRect: picked.rect)
                : .area(picked.still, pixelRect: picked.rect))
    }

    // MARK: Mode bar

    private var choices: [ModeChoice] {
        if case .modeBar(_, let choices) = mode { choices } else { [] }
    }

    /// The mode bar's frame while it shows: over a settled selection, or below `idlePoint`
    /// while nothing is selected; nil during a drag and in other modes.
    private var bar: CGRect? {
        guard !choices.isEmpty, reshaping == nil else { return nil }
        let size = CGSize(
            width: CGFloat(choices.count) * Self.choiceSize.width + 2 * Self.barInset,
            height: Self.choiceSize.height + 2 * Self.barInset)
        if settled, let selection {
            return SelectionMath.barFrame(
                for: selection, cursor: .zero, size: size, in: visibleBounds)
        }
        guard anchor == nil, let idlePoint else { return nil }
        return SelectionMath.barFrame(for: nil, cursor: idlePoint, size: size, in: visibleBounds)
    }

    private func choiceFrame(_ index: Int, in bar: CGRect) -> CGRect {
        CGRect(
            origin: CGPoint(
                x: bar.minX + Self.barInset + CGFloat(index) * Self.choiceSize.width,
                y: bar.minY + Self.barInset),
            size: Self.choiceSize)
    }

    private func choiceIndex(at point: CGPoint) -> Int? {
        guard let bar, bar.contains(point) else { return nil }
        return choices.indices.first { choiceFrame($0, in: bar).contains(point) }
    }

    private func isAvailable(_ choice: ModeChoice) -> Bool {
        !choice.usesArea || (settled && selectedPixels != nil)
    }

    /// Runs `choice` on the selection, or without it; nothing while it is unavailable.
    private func choose(_ choice: ModeChoice) {
        guard isAvailable(choice) else { return }
        guard choice.usesArea else { return finish(.chosen(id: choice.id)) }
        if let picked = selectedPixels {
            finish(.chosenArea(id: choice.id, picked.still, pixelRect: picked.rect))
        }
    }

    /// A wheel over a settled scrolling or mode-bar selection starts a scrolling capture with
    /// the user scrolling. This first event lands on the overlay, so the page hasn't moved when
    /// the first frame is taken. Fingers resting on the trackpad send wheel events that move
    /// nothing; those aren't scrolling.
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 || event.scrollingDeltaX != 0,
            settled, let mode, let selection,
            selection.contains(convert(event.locationInWindow, from: nil))
        else { return }
        switch mode {
        case .scrollingArea, .modeBar: break
        case .area, .window, .recordingArea: return
        }
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

    /// The start button's title and size: Start Scrolling Capture, or Record; nil in modes
    /// without one.
    private var startButtonStyle: (title: String, size: CGSize)? {
        switch mode {
        case .scrollingArea: (Self.startTitle, Self.startButtonSize)
        case .recordingArea: (Self.recordTitle, Self.recordButtonSize)
        default: nil
        }
    }

    /// The start button's frame while a scrolling-area or recording-area selection waits; nil
    /// otherwise.
    private var startButton: CGRect? {
        guard let style = startButtonStyle, settled, reshaping == nil, let selection else {
            return nil
        }
        return SelectionMath.startButtonFrame(for: selection, size: style.size, in: visibleBounds)
    }

    override func keyDown(with event: NSEvent) {
        // F, by character so any layout's F: the display under the pointer, when recording.
        if case .recordingArea = mode,
            event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
            event.charactersIgnoringModifiers?.lowercased() == "f"
        {
            return wholeDisplay()
        }
        switch Int(event.keyCode) {
        case 53: finish(.cancelled)  // Esc
        case 49: moving = true  // Space
        case 36, 76:  // Return, Enter: the mode bar's first area choice, else start
            if let first = choices.first(where: \.usesArea) {
                choose(first)
            } else if settled {
                confirm()
            }
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
            case .area, .scrollingArea, .modeBar: return selection
            case .recordingArea: return selection ?? hoveredArea
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
            if settled { drawHandles(on: highlight) }
            if mode.isArea { drawSizeLabel(for: highlight, avoiding: startButton ?? bar) }
        }
        if selection != nil, let target = hoveredArea { drawWindowTarget(target) }
        if let startButton, let style = startButtonStyle {
            drawStartButton(style.title, in: startButton)
        }
        if let bar { drawBar(in: bar) }
        // While drawing or resizing; not while moving, nor over the bar.
        let shaping = !settled || reshaping?.grip.isEmpty == false
        if mode.isArea, shaping, let cursor, bar?.contains(cursor) != true {
            if selection == nil { drawCrosshair(at: cursor) }
            drawLoupe(at: cursor, in: still)
        }
    }

    /// The window a click would select while another selection is settled: a dashed outline, so
    /// it doesn't read as the selection.
    private func drawWindowTarget(_ rect: CGRect) {
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        outline.setLineDash([6, 4], count: 2, phase: 0)
        outline.stroke()
    }

    /// Squares at the corners and edge midpoints of a settled selection: what can be dragged.
    private func drawHandles(on rect: CGRect) {
        let side: CGFloat = 7
        for x in [rect.minX, rect.midX, rect.maxX] {
            for y in [rect.minY, rect.midY, rect.maxY] where x != rect.midX || y != rect.midY {
                let handle = NSBezierPath(
                    rect: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
                NSColor.white.setFill()
                handle.fill()
                NSColor.black.withAlphaComponent(0.5).setStroke()
                handle.lineWidth = 1
                handle.stroke()
            }
        }
    }

    /// Each choice as its symbol over its title and hotkey; an unavailable one is dimmed, the
    /// one under the pointer lit.
    private func drawBar(in frame: CGRect) {
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
        for (index, choice) in choices.enumerated() {
            let cell = choiceFrame(index, in: frame)
            let available = isAvailable(choice)
            if available, index == hoveredChoice {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
                    .fill()
            }
            let ink = NSColor.white.withAlphaComponent(available ? 1 : 0.35)
            let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
            if let symbol = NSImage(
                systemSymbolName: choice.symbol, accessibilityDescription: choice.title)?
                .withSymbolConfiguration(configuration)
            {
                let size = symbol.size
                symbol.draw(
                    in: CGRect(
                        x: cell.midX - size.width / 2, y: cell.minY + 18 - size.height / 2,
                        width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: nil)
            }
            drawCentred(
                choice.title, font: .systemFont(ofSize: 11, weight: .medium), color: ink,
                midX: cell.midX, top: cell.minY + 31)
            if let shortcut = choice.shortcut {
                drawCentred(
                    shortcut, font: .systemFont(ofSize: 10),
                    color: ink.withAlphaComponent(ink.alphaComponent * 0.55), midX: cell.midX,
                    top: cell.minY + 45)
            }
        }
    }

    private func drawCentred(
        _ string: String, font: NSFont, color: NSColor, midX: CGFloat, top: CGFloat
    ) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = string as NSString
        text.draw(
            at: CGPoint(x: midX - text.size(withAttributes: attributes).width / 2, y: top),
            withAttributes: attributes)
    }

    private func drawStartButton(_ title: String, in frame: CGRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2)
            .fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = title as NSString
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
