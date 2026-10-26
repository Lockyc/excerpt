import AppKit

/// The recording editor's timeline: the whole clip as a track, the trim's kept part between two
/// draggable ends, the selected blur's span above it, and the playhead. A press on an end drags
/// it; anywhere else scrubs.
@MainActor
final class TimelineView: NSView {
    static let height: CGFloat = 44
    private static let inset: CGFloat = 10
    private static let handleWidth: CGFloat = 8
    private static let trackHeight: CGFloat = 22

    var duration: Double = 1 {
        didSet { needsDisplay = true }
    }
    var trim: ClosedRange<Double> = 0...1 {
        didSet { needsDisplay = true }
    }
    var playhead: Double = 0 {
        didSet { needsDisplay = true }
    }
    /// The selected blur's span, drawn over the track; nil when nothing is selected or it covers
    /// the whole clip.
    var span: ClosedRange<Double>? {
        didSet { needsDisplay = true }
    }
    /// A press or drag away from the ends, at that time.
    var onScrub: (Double) -> Void = { _ in }
    /// A trim end dragged; `continuing` on every step after a drag's first.
    var onTrim: (_ trim: ClosedRange<Double>, _ continuing: Bool) -> Void = { _, _ in }

    private enum Drag { case start, end, scrub }
    private var drag: Drag?
    private var dragged = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var track: CGRect {
        CGRect(
            x: Self.inset, y: (bounds.height - Self.trackHeight) / 2,
            width: max(bounds.width - 2 * Self.inset, 1), height: Self.trackHeight)
    }

    private func x(_ t: Double) -> CGFloat {
        track.minX + CGFloat(t / max(duration, .ulpOfOne)) * track.width
    }

    private func time(_ x: CGFloat) -> Double {
        min(max(Double((x - track.minX) / track.width) * duration, 0), duration)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = track
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()

        let kept = CGRect(
            x: x(trim.lowerBound), y: track.minY, width: x(trim.upperBound) - x(trim.lowerBound),
            height: track.height)
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        kept.fill()
        NSColor.systemYellow.setStroke()
        let frame = NSBezierPath(rect: kept.insetBy(dx: 0, dy: 1))
        frame.lineWidth = 2
        frame.stroke()
        NSColor.systemYellow.setFill()
        for t in [trim.lowerBound, trim.upperBound] {
            NSBezierPath(
                roundedRect: CGRect(
                    x: x(t) - Self.handleWidth / 2, y: track.minY - 3, width: Self.handleWidth,
                    height: track.height + 6), xRadius: 2, yRadius: 2
            ).fill()
        }

        if let span {
            NSColor.systemPink.setFill()
            CGRect(
                x: x(span.lowerBound), y: track.minY - 7,
                width: max(x(span.upperBound) - x(span.lowerBound), 2),
                height: 3
            ).fill()
        }

        NSColor.labelColor.setFill()
        CGRect(x: x(playhead) - 1, y: 2, width: 2, height: bounds.height - 4).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let slop = Self.handleWidth
        if abs(point.x - x(trim.upperBound)) <= slop && point.x >= x(trim.lowerBound) {
            drag = .end
        } else if abs(point.x - x(trim.lowerBound)) <= slop {
            drag = .start
        } else {
            drag = .scrub
        }
        dragged = false
        follow(point)
    }

    override func mouseDragged(with event: NSEvent) {
        follow(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    private func follow(_ point: CGPoint) {
        let t = time(point.x)
        switch drag {
        case .start?:
            onTrim(min(t, trim.upperBound)...trim.upperBound, dragged)
            dragged = true
        case .end?:
            onTrim(trim.lowerBound...max(t, trim.lowerBound), dragged)
            dragged = true
        case .scrub?:
            onScrub(t)
        case nil:
            break
        }
    }
}
