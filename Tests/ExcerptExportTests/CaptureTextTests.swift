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
    @Test(arguments: [
        EditDocument(scale: 1, cuts: privacyCuts, annotations: [privacyBlur], salt: 7),
        EditDocument(
            scale: 2, cuts: privacyCuts, crop: PixelRect(x: 10, y: 15, width: 375, height: 560),
            annotations: [privacyBlur], salt: 7),
    ])
    func theRecogniserSeesOnlyKeptPixelsOfTheRender(edits: EditDocument) throws {
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
        #expect(recorder.images.count == 4)
        let tornEdge = Int(8 * edits.scale)
        let hidden = [ColourWords.palette[2].colour, ColourWords.palette[3].colour]
        for (image, region) in zip(recorder.images, regions) {
            let rect = region.rect
            for gap in render.map.rows.gaps {
                #expect(!(rect.y..<(rect.y + rect.height)).overlaps(gap.destination))
            }
            for gap in render.map.columns.gaps {
                #expect(!(rect.x..<(rect.x + rect.width)).overlaps(gap.destination))
            }
            let seen = PixelBuffer(image)
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
}
