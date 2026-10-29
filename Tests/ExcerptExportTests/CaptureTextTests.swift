import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptExport

@Suite struct CaptureTextTests {
    /// Review focus: a capture with no text writes nothing, never an error.
    @Test func aCaptureWithNoTextIsEmpty() throws {
        let image = ColourWords.page(width: 300, height: 300, words: [:])
        #expect(try CaptureText.read(image, scale: 2, recognizer: ColourWords()) == "")
    }

    @Test func aPlainImageReadsWhole() throws {
        let image = ColourWords.page(
            width: 300, height: 4_000, words: ["alpha": (20, 20), "omega": (200, 3_900)])
        #expect(
            try CaptureText.read(image, scale: 2, recognizer: ColourWords()) == "alpha\n\nomega\n")
    }

    static let grey = RGBA(r: 230, g: 230, b: 230, a: 255)

    @Test func panesOnDifferentBackgroundsAreReadOneAfterTheOther() throws {
        // A grey pane beside a white one, their lines spaced so they don't pair off.
        let painted = PixelBuffer(
            ColourWords.page(
                width: 400, height: 60,
                words: ["alpha": (10, 10), "beta": (10, 24), "left": (250, 15), "right": (250, 29)])
        )
        let image = Fixtures.paint(width: 400, height: 60) { x, y in
            let pixel = painted[x: x, y: y]
            return pixel == ColourWords.white && x < 200 ? Self.grey : pixel
        }
        #expect(
            try CaptureText.read(image, scale: 1, recognizer: ColourWords())
                == "alpha\nbeta\n\nleft\nright\n")
    }

    @Test func aBackgroundChangesWhereMostRowsDifferAcrossTheGutter() {
        // Grey left of x = 100 on the top 60 rows, white everywhere else.
        let image = Fixtures.paint(width: 200, height: 100) { x, y in
            x < 100 && y < 60 ? Self.grey : ColourWords.white
        }
        #expect(CaptureText.backgroundChanges(image, gutter: 80..<120, rows: 0..<60))
        #expect(!CaptureText.backgroundChanges(image, gutter: 80..<120, rows: 0..<100))
        #expect(!CaptureText.backgroundChanges(image, gutter: 120..<180, rows: 0..<60))
        #expect(CaptureText.backgroundChanges(image, gutter: -20..<120, rows: -5..<60))
        #expect(!CaptureText.backgroundChanges(image, gutter: 80..<120, rows: 200..<300))
    }

    @Test func tallImagesAreSlicedAndEveryRowIsOwnedOnce() {
        // 3,136 rows at 2× fit whole; 5,900 are three 3,000-row slices.
        #expect(
            CaptureText.regions(width: 300, height: 3_136, scale: 2).map(\.rect)
                == [PixelRect(x: 0, y: 0, width: 300, height: 3_136)])
        let regions = CaptureText.regions(width: 300, height: 5_900, scale: 2)
        #expect(regions.map(\.rect.height) == [3_000, 3_000, 3_000])
        #expect(regions.first?.owned.lowerBound == 0)
        #expect(regions.last?.owned.upperBound == 5_900)
        for (a, b) in zip(regions, regions.dropFirst()) {
            #expect(a.owned.upperBound == b.owned.lowerBound)
        }
    }

    /// Slices are 0..<1500, 1400..<2900 and 1900..<3400, owning 0..<1450, 1450..<2400 and the
    /// rest. `alpha` lies wholly in the first two slices; `beta` straddles the first slice's bottom
    /// edge, so that slice reads only its top rows and the second reads it whole.
    @Test func aRunTwoSlicesShareIsReadOnce() throws {
        let image = ColourWords.page(
            width: 200, height: 3_400, words: ["alpha": (20, 1_440), "beta": (20, 1_495)])
        #expect(
            try CaptureText.read(image, scale: 1, recognizer: ColourWords()) == "alpha\n\nbeta\n")
    }

    @Test func anImageTooThinForALineIsNotRead() throws {
        let recorder = RecordingRecognizer()
        _ = try CaptureText.read(
            Fixtures.sheet(width: 200, height: 4), scale: 1, recognizer: recorder)
        #expect(recorder.images.isEmpty)
    }

    /// A recogniser's run with non-finite bounds is dropped, never converted to a row.
    @Test func runsWithNonFiniteBoundsAreDropped() throws {
        struct Broken: TextRecognizer {
            func recognize(_ image: CGImage) throws -> [RecognizedText] {
                [
                    RecognizedText("nan", CGRect(x: 0, y: CGFloat.nan, width: 10, height: 10)),
                    RecognizedText("inf", CGRect(x: 0, y: 0, width: 10, height: CGFloat.infinity)),
                    RecognizedText("huge", CGRect(x: 0, y: 1e300, width: 10, height: 10)),
                    RecognizedText("kept", CGRect(x: 2, y: 2, width: 10, height: 10)),
                ]
            }
        }
        let image = Fixtures.sheet(width: 100, height: 100)
        #expect(try CaptureText.read(image, scale: 1, recognizer: Broken()) == "kept\n")
        let runs = [
            RecognizedText("nan", CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 10, height: 10)),
            RecognizedText("kept", CGRect(x: 2, y: 2, width: 10, height: 10)),
        ]
        #expect(CaptureText.compose(runs) == "kept\n")
    }

    @Test func aRegionFlatterThanTheAspectIsPaddedOnItsShortSide() {
        let strip = CaptureText.Canvas(width: 2980, height: 76)
        #expect(strip.width == 2980 && strip.height == 373)
        #expect(strip.content == PixelRect(x: 0, y: 148, width: 2980, height: 76))
        let column = CaptureText.Canvas(width: 20, height: 400)
        #expect(column.width == 50 && column.height == 400)
        #expect(column.content == PixelRect(x: 15, y: 0, width: 20, height: 400))
        let page = CaptureText.Canvas(width: 800, height: 100)
        #expect(page.width == 800 && page.height == 100)
        #expect(page.content == PixelRect(x: 0, y: 0, width: 800, height: 100))
    }

    /// Review focus: padding is bounded, so a very wide, very short image can't make a canvas of
    /// gigabytes. It pads only as far as `Canvas.maximumPixels` allows.
    @Test func paddingNeverGrowsACanvasPastItsLimit() {
        let strip = CaptureText.Canvas(width: 100_000, height: 8)
        #expect(strip.width == 100_000 && strip.height == 160)
        #expect(strip.content == PixelRect(x: 0, y: 76, width: 100_000, height: 8))
        let band = CaptureText.Canvas(width: 50_000, height: 40)
        #expect(band.width == 50_000 && band.height == 320)
        let column = CaptureText.Canvas(width: 8, height: 100_000)
        #expect(column.width == 160 && column.height == 100_000)
        // Past 16 megapixels a region may grow to four times its own pixels.
        let full = CaptureText.Canvas(width: 400_000, height: 40)
        #expect(full.width == 400_000 && full.height == 160)
        for canvas in [strip, band, column, full] {
            let region = canvas.content.width * canvas.content.height
            #expect(
                canvas.width * canvas.height
                    <= max(region, CaptureText.Canvas.maximumPixels(region: region)))
        }
        #expect(CaptureText.Canvas.maximumPixels(region: 1_000) == 16_000_000)
        #expect(CaptureText.Canvas.maximumPixels(region: 5_000_000) == 20_000_000)
    }

    @Test func aVeryWideShortImageIsShownOnABoundedCanvas() throws {
        for (width, height) in [(100_000, 8), (50_000, 40)] {
            let recorder = RecordingRecognizer()
            _ = try CaptureText.read(
                Fixtures.sheet(width: width, height: height), scale: 1, recognizer: recorder)
            #expect(recorder.images.count == 1)
            let shown = recorder.images[0]
            #expect(shown.width == width)
            #expect(shown.width * shown.height <= 16_000_000)
        }
    }
}
