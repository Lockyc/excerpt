/// Where a scrolling capture is.
public enum ScrollPhase: Equatable, Sendable {
    /// Excerpt scrolls the page a step at a time.
    case auto
    /// The user scrolls; frames are sampled and stitched as they arrive.
    case manual(ManualReason)
    /// Stopped short of the end; waiting for the user to save (Return) or discard (Esc).
    case halted(HaltReason)
    /// Reached the end of the page: save.
    case finished
}

public enum ManualReason: Equatable, Sendable {
    /// Excerpt can't post scroll events without Accessibility access.
    case accessibility
    /// Auto-scroll steps didn't move the page before it had moved at all.
    case noMovement
    /// The pointer left the region (or couldn't be moved there), so a scroll step would land
    /// somewhere else.
    case pointerMoved
    /// A scroll event couldn't be made.
    case eventFailed
}

public enum HaltReason: Equatable, Sendable {
    /// The next frame didn't match.
    case uncertain
    /// The stitch reached its maximum height; what is stitched so far is kept.
    case limit
}

/// The HUD's two lines.
public struct ScrollHUDText: Equatable, Sendable {
    public let title: String
    public let detail: String

    /// The HUD while Excerpt scrolls: also what it shows before the first frame arrives.
    public static let scrolling = ScrollHUDText(
        title: "Scrolling the page", detail: "Return when done · Esc cancels")
}

/// The rules of a scrolling capture over the stitch: when to keep scrolling, when the page has
/// ended, when to hand scrolling to the user and when to stop and ask.
public struct ScrollSession: Sendable {
    /// Each auto-scroll step, as a share of the region's height.
    public static let stepShare = 0.6
    /// Consecutive auto-scroll steps that don't move the page before it counts as stopped.
    public static let stillStepsToStop = 2

    public private(set) var stitcher: Stitcher
    public private(set) var phase: ScrollPhase
    /// Manual: the newest frame didn't match where the stitch ends.
    public private(set) var offTrack = false
    public let scale: Double
    private var stillSteps = 0
    private var moved = false

    /// Starts in `.auto` when Excerpt can scroll the page, `.manual(.accessibility)` when not.
    public init(
        first: PixelBuffer, scale: Double, canAutoScroll: Bool,
        maximumHeight: Int = Stitcher.defaultMaximumHeight
    ) {
        stitcher = Stitcher(first: first, scale: scale, maximumHeight: maximumHeight)
        phase = canAutoScroll ? .auto : .manual(.accessibility)
        self.scale = scale
    }

    /// The distance of one auto-scroll step, in points.
    public static func stepPoints(regionHeightPoints: Double) -> Double {
        regionHeightPoints * stepShare
    }

    /// Auto: the settled frame after one scroll step. Any `.appended`, even of zero rows (the
    /// page moved under a footer that grew), is movement.
    public mutating func stepped(_ frame: PixelBuffer) {
        guard phase == .auto else { return }
        switch stitcher.add(frame) {
        case .appended:
            moved = true
            stillSteps = 0
        case .noMovement:
            stillSteps += 1
            if stillSteps >= Self.stillStepsToStop {
                phase = moved ? .finished : .manual(.noMovement)
            }
        case .uncertain: phase = .halted(.uncertain)
        case .reachedLimit: phase = .halted(.limit)
        }
    }

    /// Manual: a frame sampled while the user scrolls. A frame that doesn't match is skipped,
    /// not a stop: the user can scroll back to where the stitch ends.
    public mutating func sampled(_ frame: PixelBuffer) {
        guard case .manual = phase else { return }
        switch stitcher.add(frame) {
        case .appended, .noMovement: offTrack = false
        case .uncertain: offTrack = true
        case .reachedLimit: phase = .halted(.limit)
        }
    }

    /// Auto-scroll can't go on (Accessibility was turned off, the pointer left the region, or
    /// a scroll event couldn't be made): the user scrolls from here.
    public mutating func fallBack(_ reason: ManualReason) {
        if phase == .auto { phase = .manual(reason) }
    }

    /// The stitch's height, as the preview labels it.
    public var heightText: String { LengthText.points(stitcher.height, scale: scale) }

    public var hud: ScrollHUDText {
        let decide = "Return saves what's stitched · Esc discards it"
        switch phase {
        case .auto:
            return .scrolling
        case .manual(let reason):
            let detail: String
            if offTrack {
                detail = "This part doesn't match: scroll back to where the preview ends"
            } else {
                switch reason {
                case .accessibility:
                    detail =
                        "To scroll automatically, allow Excerpt in Privacy & Security → Accessibility"
                case .noMovement: detail = "The page didn't scroll on its own"
                case .pointerMoved:
                    detail = "Move the pointer back over the region, or scroll it yourself"
                case .eventFailed: detail = "Excerpt couldn't send scroll events"
                }
            }
            return ScrollHUDText(
                title: "Scroll the page yourself · Return when done", detail: detail)
        case .halted(.uncertain):
            return ScrollHUDText(
                title: "Stopped at \(heightText): the next part didn't match", detail: decide)
        case .halted(.limit):
            return ScrollHUDText(
                title:
                    "Stopped at the \(LengthText.points(stitcher.maximumHeight, scale: scale)) height limit",
                detail: decide)
        case .finished:
            return ScrollHUDText(title: "Reached the end of the page", detail: "")
        }
    }
}
