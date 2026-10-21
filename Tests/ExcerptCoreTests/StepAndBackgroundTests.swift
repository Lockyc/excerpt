import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct StepAndBackgroundTests {
    let sheet = Fixtures.sheet(width: 600, height: 800)
    let white = RGBA(r: 255, g: 255, b: 255, a: 255)

    @Test func aBackgroundPadsTheTextBounds() {
        let origin = CGPoint(x: 100, y: 100)
        let plain = Annotation(id: 1, shape: .text(origin: origin, string: "Hi"))
        var onPill = plain
        onPill.shape = .text(origin: origin, string: "Hi", background: true)
        let text = AnnotationGeometry.textRect(of: plain, scale: 2)!
        #expect(AnnotationGeometry.bounds(of: plain, scale: 2) == text)
        let pixelSize = AnnotationGeometry.textPixelSize(plain, scale: 2)
        #expect(
            AnnotationGeometry.bounds(of: onPill, scale: 2)
                == text.insetBy(dx: -0.35 * pixelSize, dy: -0.15 * pixelSize))
        #expect(AnnotationGeometry.textRect(of: onPill, scale: 2) == text)
    }

    @Test func aStepIsItsCircle() {
        let step = Annotation(id: 1, shape: .step(center: CGPoint(x: 100, y: 50)), width: .medium)
        #expect(
            AnnotationGeometry.bounds(of: step, scale: 2)
                == CGRect(x: 60, y: 10, width: 80, height: 80))
    }

    @Test func deletingAStepRenumbersTheRest() {
        let steps = (1...3).map {
            Annotation(id: $0 * 10, shape: .step(center: CGPoint(x: $0, y: 0)))
        }
        let arrow = Annotation(id: 5, shape: .arrow(tail: .zero, head: CGPoint(x: 9, y: 9)))
        #expect(
            AnnotationGeometry.stepNumbers([steps[0], arrow, steps[1], steps[2]])
                == [10: 1, 20: 2, 30: 3])
        #expect(AnnotationGeometry.stepNumbers([steps[0], steps[2]]) == [10: 1, 30: 2])
        #expect(AnnotationGeometry.stepNumbers([steps[2], steps[0]]) == [30: 1, 10: 2])
    }

    @Test func stepsNumberOnFromTheFirstStep() {
        let steps = (1...3).map {
            Annotation(id: $0 * 10, shape: .step(center: CGPoint(x: $0, y: 0)))
        }
        #expect(AnnotationGeometry.stepNumbers([steps[0], steps[2]], first: 4) == [10: 4, 30: 5])
        #expect(AnnotationGeometry.stepCount([steps[0], steps[2]]) == 2)
    }

    @Test func aFirstStepChangesTheRenderedNumber() {
        let step = Annotation(id: 1, shape: .step(center: CGPoint(x: 300, y: 400)))
        let one = Renderer.render(sheet, edits: EditDocument(scale: 1, annotations: [step]))
        let seven = Renderer.render(
            sheet, edits: EditDocument(scale: 1, annotations: [step], firstStep: 7))
        #expect(PixelBuffer(one.image) != PixelBuffer(seven.image))
    }

    @Test func aStepWhollyInsideACutIsHidden() {
        let map = RenderMap(
            crop: PixelRect(x: 0, y: 0, width: 400, height: 400),
            rows: AxisMap(extent: 400, bands: [100..<300], gap: 36),
            columns: AxisMap(extent: 400, bands: [], gap: 36))
        let inside = Annotation(id: 1, shape: .step(center: CGPoint(x: 50, y: 200)))
        let outside = Annotation(id: 2, shape: .step(center: CGPoint(x: 50, y: 350)))
        #expect(AnnotationGeometry.hiddenCount([inside, outside], map: map, scale: 1) == 1)
    }

    @Test func yellowTakesBlackInk() {
        #expect(Palette.yellow.contrastingInk == RGBA(r: 0, g: 0, b: 0, a: 255))
        #expect(
            Palette.allCases.filter { $0 != .yellow }.allSatisfy { $0.contrastingInk == white })
    }

    @Test func aBackgroundIsAPillInTheColourWithContrastingInk() {
        let text = Annotation(
            id: 1, shape: .text(origin: CGPoint(x: 100, y: 100), string: "Wide", background: true),
            color: .blue)
        let out = PixelBuffer(
            Renderer.render(sheet, edits: EditDocument(scale: 2, annotations: [text])).image)
        let rect = AnnotationGeometry.textRect(of: text, scale: 2)!
        let pixelSize = AnnotationGeometry.textPixelSize(text, scale: 2)
        // In the left padding, beside the line's middle: the pill.
        #expect(out[x: Int(rect.minX - 0.2 * pixelSize), y: Int(rect.midY)] == Palette.blue.rgba)
        // Some of the glyphs are white ink.
        #expect(
            (Int(rect.minX)..<Int(rect.maxX)).contains { out[x: $0, y: Int(rect.midY)] == white })
    }

    @Test func aStepIsAFilledCircleInsideAWhiteRing() {
        let step = Annotation(
            id: 1, shape: .step(center: CGPoint(x: 300, y: 400)), color: .green, width: .medium)
        let out = PixelBuffer(
            Renderer.render(sheet, edits: EditDocument(scale: 2, annotations: [step])).image)
        let d = AnnotationGeometry.stepDiameter(step, scale: 2)
        #expect(out[x: 300, y: Int(400 + 0.32 * d)] == Palette.green.rgba)  // below the digit
        #expect(out[x: 300, y: Int(400 + 0.46 * d)] == white)  // the ring
    }

    @Test func twoDigitStepNumbersStayInsideTheCircle() {
        // Twelve steps; the last reads "12", and nothing it draws reaches past its circle.
        let steps = (1...12).map {
            Annotation(
                id: $0, shape: .step(center: CGPoint(x: 45 * $0, y: 400)), color: .black,
                width: .thin)
        }
        let out = PixelBuffer(
            Renderer.render(sheet, edits: EditDocument(scale: 1, annotations: steps)).image)
        let base = PixelBuffer(sheet)
        let r = Int(AnnotationGeometry.stepDiameter(steps[11], scale: 1) / 2)
        let cx = 45 * 12
        for x in [cx - r - 2, cx + r + 2] { #expect(out[x: x, y: 400] == base[x: x, y: 400]) }
        #expect((cx - 6...cx + 6).contains { out[x: $0, y: 400] == white })
    }

    @Test func textBackgroundsGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 400)
        let notes = Palette.allCases.enumerated().map { i, color in
            Annotation(
                id: i + 1,
                shape: .text(
                    origin: CGPoint(x: 30 + 190 * (i % 3), y: 40 + 110 * (i / 3)),
                    string: color.rawValue.capitalized, background: true),
                color: color, width: .thin)
        }
        let twoLines = Annotation(
            id: 7,
            shape: .text(origin: CGPoint(x: 30, y: 270), string: "Totals\nQ3", background: true),
            color: .red, width: .thin)
        try Golden.check(
            Renderer.render(image, edits: EditDocument(scale: 2, annotations: notes + [twoLines]))
                .image,
            named: "render-text-backgrounds")
    }

    @Test func stepsGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 300)
        let widths: [StrokeWidth] = [.thin, .medium, .thick]
        var steps = widths.enumerated().map { i, width in
            Annotation(
                id: i + 1, shape: .step(center: CGPoint(x: 80 + 150 * i, y: 100)),
                color: Palette.allCases[i], width: width)
        }
        // Steps 4 to 11 fill the row below, so the last reads "11".
        steps += (4...11).map {
            Annotation(
                id: $0, shape: .step(center: CGPoint(x: 60 * ($0 - 3), y: 230)),
                color: $0 == 11 ? .black : .yellow, width: .thin)
        }
        try Golden.check(
            Renderer.render(image, edits: EditDocument(scale: 2, annotations: steps)).image,
            named: "render-steps")
    }
}
