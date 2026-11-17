import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct ScrollChromeTests {
    func pageFrame() -> PixelBuffer {
        ScrollFixtures.frame(
            ScrollFixtures.page(width: 90, height: 1000), offset: 0, viewport: 200)
    }

    @Test func opaqueFramesHaveNoShapedRows() {
        #expect(
            ScrollChrome.window(shapeOf: ScrollFixtures.page(width: 90, height: 200))
                == ScrollChrome(fixedTop: 0, fixedBottom: 0, fillsScrollBar: true))
    }

    @Test func roundedCornersAreShapedRows() {
        let chrome = ScrollChrome.window(
            shapeOf: ScrollFixtures.windowShaped(pageFrame(), radius: 12, edge: 0))
        #expect(chrome.fixedTop == 12 && chrome.fixedBottom == 12)
    }

    @Test func anEdgeBorderOnEveryRowIsNotShape() {
        let chrome = ScrollChrome.window(
            shapeOf: ScrollFixtures.windowShaped(pageFrame(), radius: 12, edge: 1))
        #expect(chrome.fixedTop == 12 && chrome.fixedBottom == 12)
    }
}
