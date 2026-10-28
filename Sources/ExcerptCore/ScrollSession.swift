/// Where a scrolling capture is.
public enum ScrollPhase: Equatable, Sendable {
    /// Excerpt scrolls the page a step at a time.
    case auto
    /// Steps didn't move the page before it had moved at all: Excerpt steps it up, then back
    /// down, to tell a page already at its end from one that doesn't scroll.
    case checkingEnd(EndCheck)
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
    /// Auto-scroll steps didn't move the page before it had moved at all, nor did a step up.
    case noMovement
    /// The pointer left the region (or couldn't be moved there), so a scroll step would land
    /// somewhere else.
    case pointerMoved
    /// A scroll event couldn't be made.
    case eventFailed
    /// Before the page had moved by the distance posted, a step moved it much further or less
    /// far: the app scales wheel events, so steps can't be checked against their travel.
    case unexpectedTravel
    /// The user scrolled the page themselves.
    case userScrolled
}

/// The step an end check waits on: up, away from the end, or back down to where it started.
public enum EndCheck: Equatable, Sendable { case up, back }

public enum HaltReason: Equatable, Sendable {
    /// The next frame didn't match.
    case uncertain
    /// The stitch reached its maximum height; what is stitched so far is kept.
    case limit
}

/// The HUD's two lines, and how it marks them.
public struct ScrollHUDText: Equatable, Sendable {
    /// Under way; something needs the user's attention; finished.
    public enum Tone: Equatable, Sendable { case progress, attention, done }

    public let title: String
    public let detail: String
    public let tone: Tone

    public init(title: String, detail: String, tone: Tone) {
        self.title = title
        self.detail = detail
        self.tone = tone
    }

    /// The HUD while Excerpt scrolls: also what it shows before the first frame arrives.
    public static let scrolling = ScrollHUDText(
        title: "Scrolling the page", detail: "Return when done · Esc cancels", tone: .progress)
}

/// The rules of a scrolling capture over the stitch: when to keep scrolling, when the page has
/// ended, when to hand scrolling to the user and when to stop and ask.
public struct ScrollSession: Sendable {
    /// Each auto-scroll step, as a share of the region's height.
    public static let stepShare = 0.6
    /// Consecutive auto-scroll steps that don't move the page before it counts as stopped.
    public static let stillStepsToStop = 2
    /// How far an auto step may move the page, as a share of the travel posted. Further is a
    /// false match: repeated content aliases a jump of more than a frame. Shorter is believed only
    /// once the next step shows the page has ended there. Either way, before any step has moved
    /// the page within the band, the app is taken to scale wheel events and the user scrolls;
    /// after one has, the capture halts as uncertain.
    public static let travelShare: ClosedRange<Double> = 0.25...1.5

    public private(set) var stitcher: Stitcher
    public private(set) var phase: ScrollPhase
    /// Manual: the newest frame didn't match where the stitch ends.
    public private(set) var offTrack = false
    public let scale: Double
    private var stillSteps = 0
    private var moved = false
    /// Auto: a frame that moved less than a step, held out of the stitch until the next step
    /// shows whether the page ended.
    private var shortStep: PixelBuffer?
    /// The end check found the page already at its end when the capture started.
    private var startedAtEnd = false

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

    /// Auto: the settled frame after one scroll step that posted `travel` image pixels. Any
    /// `.appended`, even of zero rows (the page moved under a footer that grew), is movement.
    public mutating func stepped(_ frame: PixelBuffer, travel: Int) {
        guard phase == .auto else { return }
        if let short = shortStep {
            shortStep = nil
            let after = StitchMatcher.match(
                short, frame, ignoringRightColumns: stitcher.ignoredRightColumns)
            guard after == .still else {
                offTravel()
                return
            }
            // The page ended after the short step: it joins the stitch, and the capture is done.
            record(stitcher.add(short))
            if phase == .auto { phase = .finished }
            return
        }
        let expected = Double(travel)
        let shortest = Int((expected * Self.travelShare.lowerBound).rounded(.up))
        let longest = Int((expected * Self.travelShare.upperBound).rounded(.down))
        let range = shortest...longest
        let step = stitcher.add(frame, travel: range)
        if case .unexpectedTravel(let offset) = step {
            if offset < range.lowerBound { shortStep = frame } else { offTravel() }
            return
        }
        record(step)
    }

    /// A step's travel can't be believed: the app scales wheel events if no step has moved the
    /// page as posted, a false match if one has.
    private mutating func offTravel() {
        if moved { phase = .halted(.uncertain) } else { fallBack(.unexpectedTravel) }
    }

    private mutating func record(_ step: StitchStep) {
        switch step {
        case .appended:
            moved = true
            stillSteps = 0
        case .noMovement:
            stillSteps += 1
            if stillSteps >= Self.stillStepsToStop {
                phase = moved ? .finished : .checkingEnd(.up)
            }
        case .uncertain: phase = .halted(.uncertain)
        case .unexpectedTravel: offTravel()
        case .reachedLimit: phase = .halted(.limit)
        }
    }

    /// Manual: a frame sampled while the user scrolls. A frame that doesn't match is skipped,
    /// not a stop: the user can scroll back to where the stitch ends. One that springs back from
    /// an overscroll past the page's end takes the background it showed out of the stitch.
    public mutating func sampled(_ frame: PixelBuffer) {
        guard case .manual = phase else { return }
        switch stitcher.add(frame) {
        case .appended, .noMovement: offTrack = false
        case .uncertain, .unexpectedTravel: offTrack = !stitcher.retract(to: frame)
        case .reachedLimit: phase = .halted(.limit)
        }
    }

    /// End check: the settled frame after the step up (`.up`) or back down (`.back`). A page that
    /// moved up and came back to where it started was already at its end: the capture is the
    /// first frame, done. One that didn't move up doesn't scroll on its own, and one that came
    /// back somewhere else can't be trusted to step; either way the user scrolls from here.
    public mutating func checkedEnd(_ frame: PixelBuffer) {
        guard case .checkingEnd(let step) = phase else { return }
        // Nothing has joined the stitch: it is the first frame, where the page started.
        let start = stitcher.image
        let ignored = stitcher.ignoredRightColumns
        switch step {
        case .up:
            // Above the start, `start` is `frame` scrolled down.
            if case .moved = StitchMatcher.match(frame, start, ignoringRightColumns: ignored) {
                phase = .checkingEnd(.back)
            } else {
                phase = .manual(.noMovement)
            }
        case .back:
            if StitchMatcher.match(start, frame, ignoringRightColumns: ignored) == .still {
                startedAtEnd = true
                phase = .finished
            } else {
                phase = .manual(.unexpectedTravel)
            }
        }
    }

    /// The user saves (Return, Done). A short step still waiting for the next to confirm the
    /// page ended joins the stitch: the user, looking at the page, takes it as ended there, and
    /// reaching for Done holds the confirming step.
    public mutating func finish() {
        guard let short = shortStep else { return }
        shortStep = nil
        _ = stitcher.add(short)
    }

    /// Auto-scroll can't go on (Accessibility was turned off, the pointer left the region, or
    /// a scroll event couldn't be made): the user scrolls from here. A short step not yet
    /// believed is dropped: the user's frames are matched against the stitch's end.
    public mutating func fallBack(_ reason: ManualReason) {
        switch phase {
        case .auto, .checkingEnd: break
        default: return
        }
        phase = .manual(reason)
        shortStep = nil
    }

    /// The user scrolled the page: they scroll from here. From a stop on a frame that didn't
    /// match too, so scrolling back to where the stitch ends picks it up again. A stop at the
    /// height limit stays stopped.
    public mutating func takeOver() {
        switch phase {
        case .auto, .checkingEnd: fallBack(.userScrolled)
        case .halted(.uncertain):
            phase = .manual(.userScrolled)
            offTrack = true
        default: break
        }
    }

    /// The stitch's height, as the preview labels it.
    public var heightText: String { LengthText.points(stitcher.height, scale: scale) }

    public var hud: ScrollHUDText {
        let decide = "Return saves what's stitched · Esc discards it"
        switch phase {
        case .auto, .checkingEnd:
            return .scrolling
        case .manual(let reason):
            let detail: String
            // The user chose to scroll; any other reason is auto-scroll that couldn't go on.
            let tone: ScrollHUDText.Tone =
                offTrack || reason != .userScrolled ? .attention : .progress
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
                case .unexpectedTravel:
                    detail = "The page scrolled a different distance than Excerpt asked for"
                case .userScrolled: detail = "Esc cancels"
                }
            }
            return ScrollHUDText(
                title: "Scroll the page yourself · Return when done", detail: detail, tone: tone)
        case .halted(.uncertain):
            return ScrollHUDText(
                title: "Stopped at \(heightText): the next part didn't match", detail: decide,
                tone: .attention)
        case .halted(.limit):
            return ScrollHUDText(
                title:
                    "Stopped at the \(LengthText.points(stitcher.maximumHeight, scale: scale)) height limit",
                detail: decide, tone: .attention)
        case .finished:
            return ScrollHUDText(
                title: startedAtEnd
                    ? "Already at the end of the page" : "Reached the end of the page",
                detail: "", tone: .done)
        }
    }
}
