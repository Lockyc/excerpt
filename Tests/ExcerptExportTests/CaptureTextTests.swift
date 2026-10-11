import CoreGraphics
import ExcerptCore
import ExcerptTestSupport
import Testing

@testable import ExcerptExport

@Suite struct CaptureTextTests {
    static let words: [String: (x: Int, y: Int)] = [
        "alpha": (20, 20), "beta": (20, 100), "secret": (20, 200), "cutaway": (20, 300),
        "left": (20, 400), "right": (300, 400), "omega": (20, 500),
    ]

    /// Review focus: text never carries what a cut removed or a blur covered.
    @Test func textHoldsOnlyWhatTheRenderShowsWithEveryCutMarked() throws {
        let original = ColourWords.page(width: 400, height: 600, words: Self.words)
        let edits = EditDocument(
            scale: 1,
            cuts: [
                Cut(axis: .horizontal, lower: 280, upper: 340),
                Cut(axis: .vertical, lower: 150, upper: 250),
            ],
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 10, y: 195, width: 80, height: 20)))
            ],
            salt: 7)
        let render = Renderer.render(original, edits: edits)
        let text = try CaptureText.read(
            render.image, map: render.map, scale: 1, recognizer: ColourWords())
        #expect(
            text == """
                alpha

                beta
                [⋯ 60 px hidden]
                left [⋯ 100 px hidden] right

                omega

                """)
        #expect(!text.contains("secret"))
        #expect(!text.contains("cutaway"))
    }

    static let privacyBlur = Annotation(
        id: 1, shape: .blur(rect: CGRect(x: 10, y: 195, width: 80, height: 20)))
    static let privacyCuts = [
        Cut(axis: .horizontal, lower: 280, upper: 340),
        Cut(axis: .vertical, lower: 150, upper: 250),
    ]

    /// Review focus: the recogniser sees only kept rows by kept columns of the render. Every
    /// image it is handed is a crop of the render clear of every seam, and away from the torn
    /// edges each of its pixels is the blurred source pixel the map places there (through the
    /// crop's offset), so no seam, no label, no cut band and no unblurred pixel reaches it.
    /// A region padded to `Canvas` shows the same pixels at its `content`, and white around it.
    @Test(arguments: [
        (EditDocument(scale: 1, cuts: privacyCuts, annotations: [privacyBlur], salt: 7), 4, 0),
        (
            EditDocument(
                scale: 2, cuts: privacyCuts,
                crop: PixelRect(x: 10, y: 15, width: 375, height: 560),
                annotations: [privacyBlur], salt: 7), 4, 0
        ),
        // Full-width 40-pixel strips between and below the cuts are padded.
        (
            EditDocument(
                scale: 1,
                cuts: [
                    Cut(axis: .horizontal, lower: 280, upper: 340),
                    Cut(axis: .horizontal, lower: 380, upper: 560),
                ],
                annotations: [privacyBlur], salt: 7), 3, 2
        ),
    ])
    func theRecogniserSeesOnlyKeptPixelsOfTheRender(
        edits: EditDocument, regionCount: Int, paddedCount: Int
    ) throws {
        let original = ColourWords.page(width: 400, height: 600, words: Self.words)
        let render = Renderer.render(original, edits: edits)
        let blurred = PixelBuffer(
            Renderer.render(
                original,
                edits: EditDocument(
                    scale: edits.scale, annotations: edits.annotations, salt: edits.salt)
            ).image)
        let recorder = RecordingRecognizer()
        _ = try CaptureText.read(
            render.image, map: render.map, scale: edits.scale, recognizer: recorder)

        let crop = render.map.crop
        let regions = CaptureText.regions(of: render.map, scale: edits.scale)
        #expect(recorder.images.count == regions.count)
        #expect(recorder.images.count == regionCount)
        let white = ColourWords.white
        let tornEdge = Int(8 * edits.scale)
        let hidden = [ColourWords.palette[2].colour, ColourWords.palette[3].colour]
        var padded = 0
        defer { #expect(padded == paddedCount) }
        for (image, region) in zip(recorder.images, regions) {
            let rect = region.rect
            for gap in render.map.rows.gaps {
                #expect(!(rect.y..<(rect.y + rect.height)).overlaps(gap.destination))
            }
            for gap in render.map.columns.gaps {
                #expect(!(rect.x..<(rect.x + rect.width)).overlaps(gap.destination))
            }
            let canvas = CaptureText.Canvas(width: rect.width, height: rect.height)
            let shown = PixelBuffer(image)
            #expect(shown.width == canvas.width && shown.height == canvas.height)
            if canvas.width != rect.width || canvas.height != rect.height { padded += 1 }
            let content = canvas.content
            for y in 0..<shown.height {
                for x in 0..<shown.width
                where !(content.x..<(content.x + content.width)).contains(x)
                    || !(content.y..<(content.y + content.height)).contains(y)
                {
                    if shown[x: x, y: y] != white {
                        Issue.record("padding pixel (\(x), \(y)) of region \(rect) isn't white")
                        return
                    }
                }
            }
            let seen = PixelBuffer(image.cropping(to: content.cgRect)!)
            var leaked = 0
            defer { #expect(leaked == 0, "a cut or blurred word reached the recogniser") }
            #expect(seen == PixelBuffer(render.image.cropping(to: rect.cgRect)!))
            let rows = render.map.rows.segments.first { $0.destination == rect.y }!
            let columns = render.map.columns.segments.first { $0.destination == rect.x }!
            for y in 0..<seen.height {
                for x in 0..<seen.width {
                    if hidden.contains(seen[x: x, y: y]) { leaked += 1 }
                    let nearSeam =
                        (rows.source.lowerBound > 0 && y < tornEdge)
                        || (rows.source.upperBound < crop.height && y >= seen.height - tornEdge)
                        || (columns.source.lowerBound > 0 && x < tornEdge)
                        || (columns.source.upperBound < crop.width && x >= seen.width - tornEdge)
                    if !nearSeam {
                        let source = blurred[
                            x: crop.x + columns.source.lowerBound + x,
                            y: crop.y + rows.source.lowerBound + y]
                        if seen[x: x, y: y] != source {
                            Issue.record("pixel (\(x), \(y)) of region \(rect) is not its source")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test func aColumnCutNoLineSpansIsWrittenAtTheTop() {
        let map = Renderer.render(
            ColourWords.page(width: 400, height: 100, words: [:]),
            edits: EditDocument(scale: 2, cuts: [Cut(axis: .vertical, lower: 300, upper: 400)])
        ).map
        let text = CaptureText.compose(
            [RecognizedText("only", CGRect(x: 10, y: 10, width: 40, height: 10))], map: map,
            scale: 2)
        #expect(text == "[⋯ 50 px hidden]\nonly\n")
    }

    @Test func aCutAtTheTopOrBottomIsMarkedThere() {
        let map = Renderer.render(
            ColourWords.page(width: 200, height: 400, words: [:]),
            edits: EditDocument(
                scale: 1,
                cuts: [
                    Cut(axis: .horizontal, lower: 0, upper: 50),
                    Cut(axis: .horizontal, lower: 350, upper: 400),
                ])
        ).map
        let middle = map.rows.segments[0].destination + 20
        let text = CaptureText.compose(
            [RecognizedText("middle", CGRect(x: 10, y: middle, width: 40, height: 10))], map: map,
            scale: 1)
        #expect(text == "[⋯ 50 px hidden]\nmiddle\n[⋯ 50 px hidden]\n")
    }

    /// Review focus: a capture with no text writes nothing, never an error.
    @Test func aCaptureWithNoTextIsEmpty() throws {
        let image = ColourWords.page(width: 300, height: 300, words: [:])
        let render = Renderer.render(image, edits: EditDocument(scale: 2))
        #expect(
            try CaptureText.read(render.image, map: render.map, scale: 2, recognizer: ColourWords())
                == "")
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

    @Test func regionsSkipSeamsAndSliceTallSegments() {
        let map = Renderer.render(
            Fixtures.sheet(width: 300, height: 7_000),
            edits: EditDocument(
                scale: 2, cuts: [Cut(axis: .horizontal, lower: 1_000, upper: 1_100)])
        ).map
        let regions = CaptureText.regions(of: map, scale: 2)
        let gap = map.rows.gaps[0].destination
        #expect(
            regions.allSatisfy {
                !$0.rect.cgRect.intersects(
                    CGRect(x: 0, y: gap.lowerBound, width: 300, height: gap.count))
            })
        // 1,000 rows above the cut fit; the 5,900 below are three 3,000-row slices.
        #expect(regions.map(\.rect.height) == [1_000, 3_000, 3_000, 3_000])
        #expect(regions[1].owned.lowerBound == gap.upperBound)
        #expect(regions.last?.owned.upperBound == map.renderedHeight)
    }

    /// Slices are 0..<1500, 1400..<2900 and 1900..<3400, owning 0..<1450, 1450..<2400 and the
    /// rest. `alpha` lies wholly in the first two slices; `beta` straddles the first slice's bottom
    /// edge, so that slice reads only its top rows and the second reads it whole.
    @Test func aRunTwoSlicesShareIsReadOnce() throws {
        let image = ColourWords.page(
            width: 200, height: 3_400, words: ["alpha": (20, 1_440), "beta": (20, 1_495)])
        let render = Renderer.render(image, edits: EditDocument(scale: 1))
        let text = try CaptureText.read(
            render.image, map: render.map, scale: 1, recognizer: ColourWords())
        #expect(text == "alpha\n\nbeta\n")
    }

    @Test func aThinSegmentIsNotRead() throws {
        let image = Fixtures.sheet(width: 200, height: 300)
        let render = Renderer.render(
            image,
            edits: EditDocument(scale: 1, cuts: [Cut(axis: .horizontal, lower: 4, upper: 300)]))
        let recorder = RecordingRecognizer()
        _ = try CaptureText.read(render.image, map: render.map, scale: 1, recognizer: recorder)
        #expect(recorder.images.isEmpty)
    }

    /// Review focus: cuts multiply the regions, each one a recognition pass, so a capture cut
    /// into more than `maximumRegions` is refused before any is read.
    @Test(.timeLimit(.minutes(1))) func tooManyRegionsAreRefusedBeforeAnyIsRead() throws {
        let original = Fixtures.sheet(width: 2_000, height: 2_000)
        // 70 cuts a side, 28 pixels apart: 71 × 71 = 5,041 kept regions of 18 pixels.
        let cuts = (0..<70).flatMap { i in
            [Axis.horizontal, .vertical].map {
                Cut(axis: $0, lower: 18 + i * 28, upper: 28 + i * 28)
            }
        }
        let render = Renderer.render(original, edits: EditDocument(scale: 1, cuts: cuts, salt: 7))
        #expect(CaptureText.regions(of: render.map, scale: 1).count == 5_041)
        let recorder = RecordingRecognizer()
        #expect(throws: CaptureTextError.tooManyRegions(5_041)) {
            try CaptureText.read(render.image, map: render.map, scale: 1, recognizer: recorder)
        }
        #expect(recorder.images.isEmpty)
        #expect(CaptureText.maximumRegions == 4_000)
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
        let render = Renderer.render(
            Fixtures.sheet(width: 100, height: 100), edits: EditDocument(scale: 1, salt: 7))
        let text = try CaptureText.read(
            render.image, map: render.map, scale: 1, recognizer: Broken())
        #expect(text == "kept\n")
        let runs = [
            RecognizedText("nan", CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 10, height: 10)),
            RecognizedText("kept", CGRect(x: 2, y: 2, width: 10, height: 10)),
        ]
        #expect(CaptureText.compose(runs, map: render.map, scale: 1) == "kept\n")
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

    /// Review focus: padding is bounded, so a tiny file of a very wide, very short image can't
    /// make a canvas of gigabytes. It pads only as far as `Canvas.maximumPixels` allows.
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
            let render = Renderer.render(
                Fixtures.sheet(width: width, height: height), edits: EditDocument(scale: 1, salt: 7)
            )
            let recorder = RecordingRecognizer()
            _ = try CaptureText.read(render.image, map: render.map, scale: 1, recognizer: recorder)
            #expect(recorder.images.count == 1)
            let shown = recorder.images[0]
            #expect(shown.width == width)
            #expect(shown.width * shown.height <= 16_000_000)
        }
    }
}
