import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptCapture

struct StreamBroke: Error {}

/// A page under the region: scroll events move it (when `moves`), and each change shows two
/// identical frames, the way a page that has settled does. In manual mode the "user" scrolls to
/// each of `userOffsets` in turn, once a read has found the screen idle, as a person takes over
/// only after the page stops; when nothing is left to show, `onIdle` runs.
@MainActor
final class FakePage: FrameSource, Scroller {
    var page: PixelBuffer
    let viewport: Int
    let pixelsPerPoint: Int
    var header: PixelBuffer?
    var footer: PixelBuffer?
    var offset = 0
    var blocker: ManualReason?
    var moves = true
    /// Rows the page moves past step `n` (1 first), as momentum or a multiplier would carry it.
    var extraTravel: (Int) -> Int = { _ in 0 }
    var eventFails = false
    var userOffsets: [Int] = []
    var scrolls: [Double] = []
    var failAfterScrolls: Int?
    /// After this many steps, `blocker` becomes the given reason.
    var blockAfterScrolls: (count: Int, reason: ManualReason)?
    var onIdle: (() -> Void)?
    /// Frames left to show before the page changes again: the first frame, then two per step.
    var fresh = 1
    /// A read has found the screen idle since the page last changed.
    private var idled = false

    init(page: PixelBuffer, viewport: Int, pixelsPerPoint: Int = 1) {
        self.page = page
        self.viewport = viewport
        self.pixelsPerPoint = pixelsPerPoint
    }

    var frame: PixelBuffer {
        ScrollFixtures.frame(
            page, offset: offset, viewport: viewport, header: header, footer: footer)
    }

    func scroll(points: Double) -> Bool {
        if eventFails { return false }
        scrolls.append(points)
        if moves {
            offset = min(
                offset + Int(points) * pixelsPerPoint + extraTravel(scrolls.count),
                page.height - viewport)
        }
        if let block = blockAfterScrolls, scrolls.count == block.count { blocker = block.reason }
        fresh = 2
        idled = false
        return true
    }

    func nextFrame(timeout: Duration) async throws -> PixelBuffer? {
        if let failAfterScrolls, scrolls.count >= failAfterScrolls { throw StreamBroke() }
        if fresh > 0 {
            fresh -= 1
            return frame
        }
        if !userOffsets.isEmpty && !idled {
            idled = true
            return nil
        }
        if !userOffsets.isEmpty {
            offset = userOffsets.removeFirst()
            return frame
        }
        onIdle?()
        return nil
    }
}

/// A page that animates each scroll step for longer than the settle: 70% of the step shows within
/// the settle, and the frame at the step's end arrives after it, waiting to be read.
@MainActor
final class AnimatedPage: FrameSource, Scroller {
    let page: PixelBuffer
    let viewport: Int
    var offset = 0
    var blocker: ManualReason?
    var scrolls = 0
    /// Reads in order; empty reads as a timeout.
    private var reads: [PixelBuffer?]
    /// The step's end frame, delivered once the settle has run out.
    private var late: PixelBuffer?

    init(page: PixelBuffer, viewport: Int) {
        self.page = page
        self.viewport = viewport
        reads = [ScrollFixtures.frame(page, offset: 0, viewport: viewport)]
    }

    func scroll(points: Double) -> Bool {
        scrolls += 1
        if let late { reads.append(late) }
        late = nil
        let target = min(offset + Int(points), page.height - viewport)
        if target != offset {
            let mid = offset + (target - offset) * 7 / 10
            reads += [ScrollFixtures.frame(page, offset: mid, viewport: viewport), nil]
            late = ScrollFixtures.frame(page, offset: target, viewport: viewport)
            offset = target
        }
        return true
    }

    func nextFrame(timeout: Duration) async throws -> PixelBuffer? {
        reads.isEmpty ? nil : reads.removeFirst()
    }

}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ScrollCaptureTests {
    let page = ScrollFixtures.page(width: 90, height: 1000)

    func saved(_ outcome: ScrollOutcome) -> PixelBuffer? {
        if case .saved(let image) = outcome { image } else { nil }
    }

    func cancelled(_ outcome: ScrollOutcome) -> Bool {
        if case .cancelled = outcome { true } else { false }
    }

    @Test func autoScrollsAPageWithStickyBarsToTheEnd() async {
        let header = ScrollFixtures.bar(width: 90, height: 24, tone: 60)
        let footer = ScrollFixtures.bar(width: 90, height: 16, tone: 140)
        let fake = FakePage(page: page, viewport: 200)
        fake.header = header
        fake.footer = footer
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        let image = saved(await capture.run())
        #expect(
            image
                == ScrollFixtures.stack([
                    header, ScrollFixtures.rows(page, 24..<984), footer,
                ]))
        // Seven steps that move (the last one short, at the end), then two that don't.
        #expect(fake.scrolls.count == 9)
    }

    @Test func aLastStepFarShorterThanTheOthersIsKept() async {
        // Steps of 130 reach 780; the last moves 20 rows to the page's end.
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 130, scale: 1)
        #expect(saved(await capture.run()) == page)
        #expect(fake.scrolls.count == 9)
    }

    @Test func retinaStepsInPointsAndStitchesInPixels() async {
        let fake = FakePage(page: page, viewport: 200, pixelsPerPoint: 2)
        let step = ScrollSession.stepPoints(regionHeightPoints: 100)  // 200px at 2×
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: step, scale: 2)
        #expect(saved(await capture.run()) == page)
        #expect(fake.scrolls.first == 60)
    }

    @Test func aPageThatDoesNotScrollHandsScrollingToTheUser() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.moves = false
        fake.userOffsets = [100, 200]
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        fake.onIdle = { capture.finish() }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<400))
        #expect(fake.scrolls.count == 2)
        #expect(phases.contains(.manual(.noMovement)))
    }

    @Test func withoutAccessibilityNoEventIsPostedAndTheUserScrolls() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.blocker = .accessibility
        fake.userOffsets = [150, 300]
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        fake.onIdle = { capture.finish() }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<500))
        #expect(fake.scrolls.isEmpty)
        #expect(phases.first == .manual(.accessibility))
    }

    @Test func accessibilityTurnedOffMidCaptureFallsBackToTheUser() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.blockAfterScrolls = (2, .accessibility)
        fake.userOffsets = [300]
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        fake.onIdle = { capture.finish() }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<500))
        #expect(fake.scrolls.count == 2)
        #expect(phases.last == .manual(.accessibility))
        #expect(!phases.contains(.finished))
    }

    @Test func aPointerThatLeftTheRegionHandsScrollingToTheUser() async {
        // Steps that land elsewhere don't move the page: they must never read as its end.
        let fake = FakePage(page: page, viewport: 200)
        fake.blockAfterScrolls = (2, .pointerMoved)
        fake.userOffsets = [300]
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        fake.onIdle = { capture.finish() }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<500))
        #expect(fake.scrolls.count == 2)
        #expect(phases.last == .manual(.pointerMoved))
        #expect(!phases.contains(.finished))
    }

    @Test func aWheelEventThatCantBeMadeHandsScrollingToTheUser() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.eventFails = true
        fake.userOffsets = [100]
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        fake.onIdle = { capture.finish() }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<300))
        #expect(phases.contains(.manual(.eventFailed)))
    }

    @Test func theLimitHaltsUntilReturnThenSaves() async {
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(
            source: fake, scroller: fake, stepPoints: 120, scale: 1, maximumHeight: 500)
        capture.onChange = { if $0.phase == .halted(.limit) { capture.finish() } }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<500))
    }

    @Test func aPageThatChangesHaltsAndKeepsWhatWasStitched() async {
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var halted: ScrollSession?
        capture.onChange = { session in
            if session.stitcher.height == 440 {
                fake.page = ScrollFixtures.page(width: 90, height: 1000, seed: 77)
            }
            if session.phase == .halted(.uncertain) {
                halted = session
                capture.finish()
            }
        }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<440))
        #expect(halted?.hud.title == "Stopped at 440 px: the next part didn't match")
    }

    @Test func escFromAHaltDiscards() async {
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(
            source: fake, scroller: fake, stepPoints: 120, scale: 1, maximumHeight: 500)
        capture.onChange = { if $0.phase == .halted(.limit) { capture.cancel() } }
        #expect(cancelled(await capture.run()))
    }

    @Test func aJumpThatRepeatedContentDisguisesAsASmallMoveHalts() async {
        // StitchMatcherTests' known limit, after an honest step of 130, a jump of 280 rows over
        // blocks that repeat every 250 reads as a 30-row move. An auto step that posted 130
        // knows better.
        let base = ScrollFixtures.page(width: 90, height: 1500, seed: 3)
        let long = ScrollFixtures.paint(width: 90, height: 1500) { x, y in
            let row = y % 250
            switch row {
            case 100..<200: return base[x: x, y: row]
            case 60..<63:
                let patch = (40..<45).contains(x)
                return base[x: x, y: patch ? y : row]
            default: return ScrollFixtures.paper
            }
        }
        func frame(_ offset: Int) -> PixelBuffer {
            ScrollFixtures.frame(long, offset: offset, viewport: 200)
        }
        guard
            case .moved(30, _, _) = StitchMatcher.match(
                frame(130), frame(410), ignoringRightColumns: 0)
        else {
            Issue.record("the jump no longer aliases as a 30-row move")
            return
        }
        let fake = FakePage(page: long, viewport: 200)
        fake.extraTravel = { $0 == 2 ? 150 : 0 }
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 130, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { session in
            phases.append(session.phase)
            if session.phase == .halted(.uncertain) { capture.finish() }
        }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(long, 0..<330))
        #expect(phases.last == .halted(.uncertain))
    }

    @Test func aPageThatScrollsFurtherThanPostedHandsScrollingToTheUser() async {
        // An app that scrolls twice what is posted moves 120 rows on a 60-point step.
        let fake = FakePage(page: page, viewport: 200)
        fake.extraTravel = { _ in 60 }
        fake.userOffsets = [100]
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 60, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        fake.onIdle = { capture.finish() }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<300))
        #expect(fake.scrolls.count == 1)
        #expect(phases.contains(.manual(.unexpectedTravel)))
    }

    @Test func aStepThatAnimatesPastTheSettleStillReachesTheEnd() async {
        let fake = AnimatedPage(page: page, viewport: 200)
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        var phases: [ScrollPhase] = []
        capture.onChange = { phases.append($0.phase) }
        let image = saved(await capture.run())
        #expect(image?.height == page.height)
        #expect(image == page)
        #expect(phases.last == .finished)
    }

    @Test func returnMidScrollSavesWhatIsStitched() async {
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        capture.onChange = { if $0.stitcher.height == 440 { capture.finish() } }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<440))
        #expect(fake.scrolls.count == 2)
    }

    @Test func escDiscards() async {
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        capture.onChange = { if $0.stitcher.height == 320 { capture.cancel() } }
        #expect(cancelled(await capture.run()))
    }

    @Test func returnThenEscSaves() async {
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        capture.onChange = { session in
            if session.stitcher.height == 320 {
                capture.finish()
                capture.cancel()
            }
        }
        #expect(saved(await capture.run()) == ScrollFixtures.rows(page, 0..<320))
    }

    @Test func aStreamFailureKeepsWhatWasStitched() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.failAfterScrolls = 3
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        guard case .failed(let error, let partial) = await capture.run() else {
            Issue.record("expected a failure")
            return
        }
        #expect(error is StreamBroke)
        #expect(partial == ScrollFixtures.rows(page, 0..<440))
    }

    @Test func noFirstFrameFailsWithNothingSaved() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.fresh = 0  // the screen never sends a frame
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        guard case .failed(let error, let partial) = await capture.run() else {
            Issue.record("expected a failure")
            return
        }
        #expect(error as? ScrollCaptureError == .noFrames)
        #expect(partial == nil)
    }

    @Test func escBeforeTheFirstFrameCancels() async {
        let fake = FakePage(page: page, viewport: 200)
        fake.fresh = 0
        let capture = ScrollCapture(source: fake, scroller: fake, stepPoints: 120, scale: 1)
        fake.onIdle = { capture.cancel() }
        #expect(cancelled(await capture.run()))
    }

    @Test func escEndsTheFirstFrameWaitAtOnce() async {
        // The mailbox's timeout never fires: only the cancel can end the wait.
        let timers = ManualTimers()
        let mailbox = FrameMailbox(sleep: { [timers] in await timers.sleep($0) })
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: mailbox, scroller: fake, stepPoints: 120, scale: 1)
        let run = Task { await capture.run() }
        while !mailbox.isWaiting || timers.started < 1 { await Task.yield() }
        capture.cancel()
        #expect(cancelled(await run.value))
        timers.fire(0)
    }

    @Test func cancellingTheRunningTaskCancelsTheCapture() async {
        let timers = ManualTimers()
        let mailbox = FrameMailbox(sleep: { [timers] in await timers.sleep($0) })
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: mailbox, scroller: fake, stepPoints: 120, scale: 1)
        let run = Task { await capture.run() }
        while !mailbox.isWaiting || timers.started < 1 { await Task.yield() }
        run.cancel()
        #expect(cancelled(await run.value))
        timers.fire(0)
    }

    @Test func escBeforeRunCancelsWithoutWaitingForAFrame() async {
        let timers = ManualTimers()
        let mailbox = FrameMailbox(sleep: { [timers] in await timers.sleep($0) })
        let fake = FakePage(page: page, viewport: 200)
        let capture = ScrollCapture(source: mailbox, scroller: fake, stepPoints: 120, scale: 1)
        capture.cancel()
        #expect(cancelled(await capture.run()))
        #expect(timers.started == 0)
    }
}

/// Plays back a fixed list of reads: a frame, or nil for a timeout.
@MainActor
final class ScriptedSource: FrameSource {
    var reads: [PixelBuffer?]
    /// Each read's timeout, in order.
    var timeouts: [Duration] = []
    init(_ reads: [PixelBuffer?]) { self.reads = reads }
    func nextFrame(timeout: Duration) async throws -> PixelBuffer? {
        timeouts.append(timeout)
        return reads.isEmpty ? nil : reads.removeFirst()
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SettleTests {
    let a = ScrollFixtures.page(width: 8, height: 4, seed: 1)
    let b = ScrollFixtures.page(width: 8, height: 4, seed: 2)
    let c = ScrollFixtures.page(width: 8, height: 4, seed: 3)

    func settle(_ reads: [PixelBuffer?]) async throws -> PixelBuffer {
        let source = ScriptedSource(reads)
        let fake = FakePage(page: a, viewport: 4)
        return try await ScrollCapture(source: source, scroller: fake, stepPoints: 1, scale: 1)
            .settledFrame(after: c)
    }

    @Test func twoIdenticalFramesSettle() async throws {
        #expect(try await settle([a, b, b, a]) == b)
    }

    @Test func theNewestFrameWhenTheWaitRunsOut() async throws {
        #expect(try await settle([a, b, nil, c]) == b)
    }

    @Test func noFrameMeansNothingChanged() async throws {
        #expect(try await settle([nil, a]) == c)
    }

    /// An app can move the page well after the wheel event: a still frame (a caret blinking) keeps
    /// the wait for the page's answer going, past what settling a moving page takes.
    @Test func aStillFrameKeepsWaitingForThePageToAnswer() async throws {
        let source = ScriptedSource([c, a, a])
        let fake = FakePage(page: a, viewport: 4)
        let settled = try await ScrollCapture(
            source: source, scroller: fake, stepPoints: 1, scale: 1
        ).settledFrame(after: c)
        #expect(settled == a)
        #expect(source.timeouts.prefix(2).allSatisfy { $0 > ScrollCapture.settleTime })
    }

    @Test func aFailingStreamIsNeverReadAsNothingChanged() async {
        final class Broken: FrameSource {
            func nextFrame(timeout: Duration) async throws -> PixelBuffer? { throw StreamBroke() }
        }
        let fake = FakePage(page: a, viewport: 4)
        let capture = ScrollCapture(source: Broken(), scroller: fake, stepPoints: 1, scale: 1)
        await #expect(throws: StreamBroke.self) { try await capture.settledFrame(after: c) }
    }
}
