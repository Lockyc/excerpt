import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct ScrollSessionTests {
    let page = ScrollFixtures.page(width: 90, height: 1000)

    func frame(_ offset: Int) -> PixelBuffer {
        ScrollFixtures.frame(page, offset: offset, viewport: 200)
    }

    func session(canAutoScroll: Bool = true, maximumHeight: Int = 30_000) -> ScrollSession {
        ScrollSession(
            first: frame(0), scale: 1, canAutoScroll: canAutoScroll, maximumHeight: maximumHeight)
    }

    @Test func stepsAreSixtyPercentOfTheRegionInPoints() {
        #expect(ScrollSession.stepPoints(regionHeightPoints: 600) == 360)
    }

    @Test func twoStillStepsAfterMovingAreTheEnd() {
        var s = session()
        s.stepped(frame(120))
        s.stepped(frame(120))
        #expect(s.phase == .auto)
        s.stepped(frame(120))
        #expect(s.phase == .finished)
        #expect(s.stitcher.height == 320)
    }

    @Test func aStillStepBetweenMovesDoesNotEndIt() {
        var s = session()
        s.stepped(frame(120))
        s.stepped(frame(120))
        s.stepped(frame(240))
        s.stepped(frame(240))
        #expect(s.phase == .auto)
    }

    @Test func twoStillStepsBeforeAnyMovementHandScrollingToTheUser() {
        var s = session()
        s.stepped(frame(0))
        #expect(s.phase == .auto)
        s.stepped(frame(0))
        #expect(s.phase == .manual(.noMovement))
        #expect(
            s.hud
                == ScrollHUDText(
                    title: "Scroll the page yourself · Return when done",
                    detail: "The page didn't scroll on its own"))
    }

    @Test func withoutAccessibilityTheUserScrollsFromTheStart() {
        let s = session(canAutoScroll: false)
        #expect(s.phase == .manual(.accessibility))
        #expect(s.hud.title == "Scroll the page yourself · Return when done")
        #expect(
            s.hud.detail
                == "To scroll automatically, allow Excerpt in Privacy & Security → Accessibility")
    }

    @Test func losingAccessibilityMidCaptureFallsBackKeepingTheStitch() {
        var s = session()
        s.stepped(frame(120))
        s.fallBack(.accessibility)
        #expect(s.phase == .manual(.accessibility))
        #expect(s.stitcher.height == 320)
        s.sampled(frame(200))
        #expect(s.stitcher.height == 400)
    }

    @Test func anUncertainStepHaltsAndSaysWhere() {
        var s = ScrollSession(first: frame(0), scale: 2, canAutoScroll: true)
        s.stepped(frame(120))
        s.stepped(ScrollFixtures.page(width: 90, height: 200, seed: 5))
        #expect(s.phase == .halted(.uncertain))
        #expect(
            s.hud
                == ScrollHUDText(
                    title: "Stopped at 160 px: the next part didn't match",
                    detail: "Return saves what's stitched · Esc discards it"))
        #expect(s.stitcher.height == 320)
    }

    @Test func theLimitHalts() {
        var s = session(maximumHeight: 300)
        s.stepped(frame(120))
        #expect(s.phase == .halted(.limit))
        #expect(s.hud.title == "Stopped at the 300 px height limit")
        #expect(s.stitcher.height == 300)
    }

    @Test func aManualFrameThatDoesNotMatchIsSkippedAndSaysSo() {
        var s = session(canAutoScroll: false)
        s.sampled(frame(60))
        s.sampled(frame(500))  // scrolled too far between frames
        #expect(s.offTrack)
        #expect(s.phase == .manual(.accessibility))
        #expect(s.hud.detail == "This part doesn't match: scroll back to where the preview ends")
        s.sampled(frame(150))
        #expect(!s.offTrack)
        #expect(s.stitcher.image == ScrollFixtures.rows(page, 0..<350))
    }

    @Test func manualFramesAreIgnoredInAutoAndAutoStepsInManual() {
        var s = session()
        s.sampled(frame(120))
        #expect(s.stitcher.height == 200)
        var m = session(canAutoScroll: false)
        m.stepped(frame(120))
        #expect(m.stitcher.height == 200)
    }

    @Test func heightIsShownInPoints() {
        var s = ScrollSession(first: frame(0), scale: 2, canAutoScroll: true)
        s.stepped(frame(120))
        #expect(s.heightText == "160 px")
    }

    @Test func lengthsReadInPointsWithSeparators() {
        #expect(LengthText.points(2480, scale: 2) == "1,240 px")
        #expect(LengthText.points(7, scale: 1) == "7 px")
    }

    @Test func theOpeningHUDIsTheScrollingText() {
        #expect(session().hud == .scrolling)
        #expect(ScrollHUDText.scrolling.title == "Scrolling the page")
    }

    @Test func aPointerThatLeftTheRegionHasItsOwnWording() {
        var s = session()
        s.stepped(frame(120))
        s.fallBack(.pointerMoved)
        #expect(s.phase == .manual(.pointerMoved))
        #expect(s.hud.detail == "Move the pointer back over the region, or scroll it yourself")
    }

    @Test func aFailedWheelEventIsNotBlamedOnThePage() {
        var s = session()
        s.fallBack(.eventFailed)
        #expect(s.phase == .manual(.eventFailed))
        #expect(s.hud.detail == "Excerpt couldn't send scroll events")
    }

    @Test func truncationByThePointerNeverReadsAsTheEnd() {
        var s = session()
        s.stepped(frame(120))
        s.fallBack(.pointerMoved)
        s.stepped(frame(120))
        s.stepped(frame(120))
        #expect(s.phase == .manual(.pointerMoved))
        #expect(s.hud.title != "Reached the end of the page")
    }
}
