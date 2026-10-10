import AppKit

/// One short note at the top of the screen with the pointer: what an action is doing or just
/// did. It never takes focus, and a click closes it, so it can't stand in the user's way.
/// Several flows share it; each closes only its own note.
@MainActor
enum Toast {
    /// Names one `show`; `dismiss` with it closes that note and never a later one.
    struct Token: Equatable {
        fileprivate let id: Int
    }

    private static var panel: ToastPanel?
    private static var timer: Timer?
    private static var current: Token?
    private static var nextID = 0

    /// Shows `text`, replacing any note already up; closes it after `seconds`, or leaves it up
    /// until the next `show` or its `dismiss` when nil.
    @discardableResult
    static func show(_ text: String, seconds: Double? = 3) -> Token {
        timer?.invalidate()
        timer = nil
        nextID += 1
        let token = Token(id: nextID)
        current = token
        let panel = panel ?? ToastPanel()
        self.panel = panel
        panel.show(text)
        if let seconds {
            timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { dismiss(token) }
            }
        }
        return token
    }

    /// Closes the note `token` showed, if it is still the one up.
    static func dismiss(_ token: Token) {
        guard token == current else { return }
        timer?.invalidate()
        timer = nil
        current = nil
        panel?.orderOut(nil)
    }

    /// A click closes whatever note is up.
    fileprivate static func clicked() {
        if let current { dismiss(current) }
    }
}

@MainActor
private final class ToastPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let backing = ToastBacking()

    init() {
        super.init(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
            defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backing.material = .hudWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 10
        backing.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        backing.addSubview(label)
        contentView = backing
    }

    func show(_ text: String) {
        label.stringValue = text
        let size = label.fittingSize
        let width = min(max(size.width, 120), 560) + 32
        let height = size.height + 20
        label.frame = CGRect(x: 16, y: 10, width: width - 32, height: size.height)
        backing.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let mouse = NSEvent.mouseLocation
        let screen =
            (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        setFrame(
            CGRect(
                x: screen.midX - width / 2, y: screen.maxY - height - 12, width: width,
                height: height), display: true)
        orderFrontRegardless()
    }
}

/// The note's whole surface takes the click, the first one included, though Excerpt is never
/// the active app while the note is up.
@MainActor
private final class ToastBacking: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { Toast.clicked() }
}
