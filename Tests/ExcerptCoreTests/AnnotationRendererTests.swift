import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct AnnotationRendererTests {
    let sheet = Fixtures.sheet(width: 600, height: 800)

    @Test func blursAloneLeaveTheBaseAsTheRender() {
        let edits = EditDocument(
            scale: 1,
            annotations: [
                Annotation(id: 1, shape: .blur(rect: CGRect(x: 0, y: 0, width: 50, height: 50)))
            ])
        let base = Renderer.renderBase(sheet, edits: edits).image
        #expect(PixelBuffer(Renderer.render(sheet, edits: edits).image) == PixelBuffer(base))
    }

    @Test func anArrowIsDrawnInItsColourAtTheHead() {
        let edits = EditDocument(
            scale: 2,
            annotations: [
                Annotation(
                    id: 1,
                    shape: .arrow(tail: CGPoint(x: 100, y: 400), head: CGPoint(x: 400, y: 400)),
                    color: .blue)
            ])
        let out = PixelBuffer(Renderer.render(sheet, edits: edits).image)
        #expect(out[x: 390, y: 400] == Palette.blue.rgba)  // inside the head
        #expect(out[x: 200, y: 400] == Palette.blue.rgba)  // on the shaft
        #expect(out[x: 200, y: 440] == PixelBuffer(sheet)[x: 200, y: 440])  // clear of it
    }

    @Test func anAnnotationHiddenByACutDrawsNothing() {
        let cut = Cut(axis: .horizontal, lower: 200, upper: 500)
        let hidden = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 100, y: 300, width: 200, height: 100)))
        let with = Renderer.render(
            sheet, edits: EditDocument(scale: 2, cuts: [cut], annotations: [hidden]))
        let without = Renderer.render(sheet, edits: EditDocument(scale: 2, cuts: [cut]))
        #expect(PixelBuffer(with.image) == PixelBuffer(without.image))
    }

    @Test func aRectanglePartlyInsideACutDrawsItsKeptPart() {
        let cut = Cut(axis: .horizontal, lower: 200, upper: 500)
        let rect = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 100, y: 300, width: 200, height: 300)),
            color: .green, width: .thin)
        let result = Renderer.render(
            sheet, edits: EditDocument(scale: 1, cuts: [cut], annotations: [rect]))
        let out = PixelBuffer(result.image)
        let gapEnd = result.map.rows.gaps[0].destination.upperBound
        // The bottom edge sits at original y 600, kept after the gap.
        #expect(out[x: 200, y: gapEnd + 100] == Palette.green.rgba)
        // The left edge runs from the gap's end down to the bottom edge.
        #expect(out[x: 100, y: gapEnd + 50] == Palette.green.rgba)
    }

    @Test func highlightMultipliesSoDarkContentStaysDark() {
        let edits = EditDocument(
            scale: 1,
            annotations: [
                Annotation(
                    id: 1, shape: .highlight(rect: CGRect(x: 0, y: 0, width: 600, height: 20)),
                    color: .yellow)
            ])
        let out = PixelBuffer(Renderer.render(sheet, edits: edits).image)
        let white = out[x: 30, y: 10]
        #expect(white.r == 255 && white.b < 200)  // white turned yellow
        let block = out[x: 80, y: 10]  // a blue block under the highlight
        #expect(block.b < 220 && block.r <= 40)
    }

    @Test func aViewportOfATallCaptureMatchesTheFullRender() {
        let tall = Fixtures.rowStripes(width: 200, height: 30_000)
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 10_000, upper: 25_000)],
            annotations: [
                Annotation(
                    id: 1,
                    shape: .arrow(tail: CGPoint(x: 20, y: 9_000), head: CGPoint(x: 150, y: 26_000))),
                Annotation(
                    id: 2, shape: .text(origin: CGPoint(x: 10, y: 9_950), string: "Totals"),
                    color: .black),
            ])
        let full = Renderer.render(tall, edits: edits).image
        let base = Renderer.renderBase(tall, edits: edits)
        let height = base.image.height
        let top = 9_500
        let window = 1_000
        let context = PixelBuffer.makeContext(width: 200, height: window)
        context.draw(
            base.image.cropping(to: CGRect(x: 0, y: top, width: 200, height: window))!,
            in: CGRect(x: 0, y: 0, width: 200, height: window))
        context.translateBy(x: 0, y: -CGFloat(height - top - window))
        AnnotationRenderer.draw(
            edits.annotations, map: base.map, scale: 2, in: context, canvasHeight: height)
        let expected = full.cropping(to: CGRect(x: 0, y: top, width: 200, height: window))!
        // Shifting the canvas moves where CoreGraphics' rasteriser rounds, so antialiased
        // edges may differ by a few levels; anything more is a misplaced shape.
        #expect(
            PixelBuffer(context.makeImage()!).fractionDiffering(
                from: PixelBuffer(expected), tolerance: 16) <= 0.001)
    }

    @Test func annotationsGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 400)
        let edits = EditDocument(
            scale: 2,
            annotations: [
                Annotation(
                    id: 1, shape: .highlight(rect: CGRect(x: 61, y: 41, width: 240, height: 38)),
                    color: .yellow),
                Annotation(
                    id: 2, shape: .rectangle(rect: CGRect(x: 360, y: 60, width: 180, height: 120)),
                    color: .red, width: .thin),
                Annotation(
                    id: 3,
                    shape: .arrow(tail: CGPoint(x: 120, y: 330), head: CGPoint(x: 350, y: 200)),
                    color: .blue),
                Annotation(
                    id: 4, shape: .text(origin: CGPoint(x: 380, y: 250), string: "Totals\nQ3"),
                    color: .green, width: .thin),
            ])
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-annotations")
    }

    @Test func renderOrderGolden() throws {
        // Blur from original pixels, then the crop, then a cut with its seam, then annotations:
        // an arrow across the seam, a rectangle partly inside the cut, and a note wholly inside
        // it that is not drawn.
        let image = Fixtures.sheet(width: 600, height: 800)
        let edits = EditDocument(
            scale: 2, cuts: [Cut(axis: .horizontal, lower: 281, upper: 521)],
            crop: PixelRect(x: 20, y: 21, width: 520, height: 700),
            annotations: [
                Annotation(
                    id: 1, shape: .blur(rect: CGRect(x: 60, y: 200, width: 200, height: 400))),
                Annotation(
                    id: 2,
                    shape: .arrow(tail: CGPoint(x: 450, y: 150), head: CGPoint(x: 330, y: 600)),
                    color: .red),
                Annotation(
                    id: 3, shape: .rectangle(rect: CGRect(x: 300, y: 400, width: 200, height: 200)),
                    color: .orange, width: .thin),
                Annotation(
                    id: 4, shape: .text(origin: CGPoint(x: 300, y: 350), string: "gone"),
                    color: .black),
            ],
            salt: 7)
        try Golden.check(Renderer.render(image, edits: edits).image, named: "render-order")
    }
}

extension AnnotationRendererTests {
    private func map(bands: [Range<Int>]) -> RenderMap {
        RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
            rows: AxisMap(extent: 400, bands: bands, gap: 36),
            columns: AxisMap(extent: 400, bands: [], gap: 36))
    }

    @Test func aStrokePokingOutOfABandIsCountedNotDropped() {
        // The raw rect lies inside rows 100..<200, but a thick stroke pokes out of it: the
        // renderer and the count must agree on whether it shows.
        let poking = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 10, y: 102, width: 100, height: 96)),
            color: .red, width: .thick)
        let placed = map(bands: [100..<200])
        #expect(!placed.isHidden(AnnotationGeometry.bounds(of: poking, scale: 1)))
        #expect(placed.rect(CGRect(x: 10, y: 102, width: 100, height: 96)) == nil)
        #expect(AnnotationGeometry.hiddenCount([poking], map: placed, scale: 1) == 1)
        let base = Fixtures.sheet(width: 400, height: 400)
        let edits = EditDocument(
            scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)], annotations: [poking])
        let with = PixelBuffer(Renderer.render(base, edits: edits).image)
        let without = PixelBuffer(
            Renderer.render(
                base,
                edits: EditDocument(
                    scale: 1, cuts: [Cut(axis: .horizontal, lower: 100, upper: 200)])
            ).image)
        #expect(with == without)  // counted, so nothing is drawn
    }

    @Test func aCollapsedShapeIsCountedNotDrawn() {
        // A rectangle wholly past the image's end beside the edge band collapses to nothing.
        let placed = map(bands: [300..<400])
        let collapsed = Annotation(
            id: 1, shape: .rectangle(rect: CGRect(x: 10, y: 300, width: 100, height: 100)),
            width: .thin)
        #expect(placed.rect(CGRect(x: 10, y: 300, width: 100, height: 100)) == nil)
        #expect(!AnnotationGeometry.isDrawn(collapsed, map: placed, scale: 1))
        #expect(AnnotationGeometry.hiddenCount([collapsed], map: placed, scale: 1) == 1)
    }

    @Test func anArrowInsideOneBandWithAPokingStrokeIsCountedNotDrawn() {
        let arrow = Annotation(
            id: 1, shape: .arrow(tail: CGPoint(x: 50, y: 105), head: CGPoint(x: 300, y: 195)))
        let placed = map(bands: [100..<200])
        #expect(!placed.isHidden(AnnotationGeometry.bounds(of: arrow, scale: 1)))
        #expect(!AnnotationGeometry.isDrawn(arrow, map: placed, scale: 1))
        #expect(AnnotationGeometry.hiddenCount([arrow], map: placed, scale: 1) == 1)
        let base = Fixtures.sheet(width: 400, height: 400)
        let cut = Cut(axis: .horizontal, lower: 100, upper: 200)
        let with = Renderer.render(
            base, edits: EditDocument(scale: 1, cuts: [cut], annotations: [arrow]))
        let without = Renderer.render(base, edits: EditDocument(scale: 1, cuts: [cut]))
        #expect(PixelBuffer(with.image) == PixelBuffer(without.image))
    }
}
