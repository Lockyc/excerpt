import CoreGraphics
import CoreText
import ExcerptTestSupport
import Foundation
import Testing

@testable import ExcerptCore

@Suite struct TextStyleTests {
    @Test func styleRoundTrips() throws {
        let style = TextStyle(points: 17.5, bold: false, font: .serif, alignment: .centered)
        let note = Annotation(
            id: 1,
            shape: .text(
                origin: CGPoint(x: 3, y: 4), string: "Hi", background: true, style: style))
        let data = try JSONEncoder().encode(note)
        #expect(try JSONDecoder().decode(Annotation.self, from: data) == note)
        let legacy = Annotation(id: 2, shape: .text(origin: .zero, string: "a"))
        #expect(
            !String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("style"))
    }

    @Test func legacyTextIsBoldSansAtItsWidth() {
        let legacy = Annotation(id: 1, shape: .text(origin: .zero, string: "Total"), width: .thin)
        var styled = legacy
        styled.shape = .text(
            origin: .zero, string: "Total", style: TextStyle(points: StrokeWidth.thin.textPoints))
        #expect(AnnotationGeometry.textPixelSize(legacy, scale: 2) == 40)
        #expect(
            legacy.textStyle
                == TextStyle(points: 20, bold: true, font: .sans, alignment: .left))
        #expect(Annotation(id: 3, shape: .step(center: .zero)).textStyle == nil)
        #expect(
            AnnotationGeometry.textRect(of: legacy, scale: 2)
                == AnnotationGeometry.textRect(of: styled, scale: 2))
    }

    @Test func sizeIsFree() {
        let note = Annotation(
            id: 1, shape: .text(origin: .zero, string: "a", style: TextStyle(points: 13)))
        #expect(AnnotationGeometry.textPixelSize(note, scale: 2) == 26)
    }

    @Test func centeredTextRectIsCentredOnOrigin() {
        let origin = CGPoint(x: 200, y: 50)
        func rect(_ alignment: TextAlign) -> CGRect {
            AnnotationGeometry.textRect(
                of: Annotation(
                    id: 1,
                    shape: .text(
                        origin: origin, string: "Total",
                        style: TextStyle(points: 20, alignment: alignment))),
                scale: 1)!
        }
        #expect(rect(.left).minX == 200)
        #expect(abs(rect(.centered).midX - 200) < 0.001)
        #expect(rect(.centered).minY == 50 && rect(.centered).size == rect(.left).size)
    }

    @Test func monoAdvancesAreEqual() {
        func width(_ s: String, _ font: TextFont) -> CGFloat {
            TextLayout(s, pixelSize: 30, color: .black, font: font, bold: true).size.width
        }
        #expect(abs(width("iiii", .mono) - width("MMMM", .mono)) < 0.001)
        #expect(width("iiii", .sans) < width("MMMM", .sans) - 1)
    }

    @Test func fontsDifferByFamilyAndWeight() {
        func name(_ font: TextFont, _ bold: Bool) -> String {
            CTFontCopyPostScriptName(TextLayout.font(pixelSize: 30, font: font, bold: bold))
                as String
        }
        #expect(name(.sans, true) != name(.sans, false))
        #expect(name(.mono, true) != name(.mono, false))
        #expect(name(.serif, true) != name(.serif, false))
        #expect(Set([name(.sans, false), name(.mono, false), name(.serif, false)]).count == 3)
    }

    @Test func textStylesGolden() throws {
        let image = Fixtures.sheet(width: 600, height: 300)
        func note(_ id: Int, y: Double, x: Double, _ string: String, _ style: TextStyle)
            -> Annotation
        {
            Annotation(
                id: id,
                shape: .text(origin: CGPoint(x: x, y: y), string: string, style: style),
                color: .palette(.black), width: .thin)
        }
        let notes = [
            note(1, y: 20, x: 20, "Sans regular 12pt", TextStyle(points: 12, bold: false)),
            note(2, y: 60, x: 20, "Sans bold 18pt", TextStyle(points: 18)),
            note(
                3, y: 110, x: 300, "Mono bold\ncentred",
                TextStyle(points: 18, font: .mono, alignment: .centered)),
            note(
                4, y: 200, x: 20, "Serif regular 22pt",
                TextStyle(points: 22, bold: false, font: .serif)),
        ]
        try Golden.check(
            Renderer.render(image, edits: EditDocument(scale: 2, annotations: notes)).image,
            named: "render-text-styles")
    }
}
