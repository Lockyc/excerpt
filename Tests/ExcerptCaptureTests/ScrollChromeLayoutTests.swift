import CoreGraphics
import Testing

@testable import ExcerptCapture

@Suite struct ScrollChromeLayoutTests {
    @Test func previewRowsFillThePreviewAtTheStitchWidth() {
        #expect(
            ScrollChromeLayout.previewRows(stitchWidth: 1000, size: CGSize(width: 100, height: 250))
                == 2500)
        #expect(
            ScrollChromeLayout.previewRows(stitchWidth: 1000, size: CGSize(width: 400, height: 100))
                == 250)
    }

    @Test func aNarrowOrEmptyPreviewStillShowsOneRow() {
        #expect(
            ScrollChromeLayout.previewRows(stitchWidth: 10, size: CGSize(width: 1000, height: 1))
                == 1)
        #expect(
            ScrollChromeLayout.previewRows(stitchWidth: 1000, size: CGSize(width: 0, height: 200))
                == 1)
        #expect(ScrollChromeLayout.previewRows(stitchWidth: 1000, size: .zero) == 1)
    }
}
