import Foundation
import Testing

@testable import ExcerptCore

@Suite struct AnnotationColorTests {
    @Test func paletteEncodesAsBareString() throws {
        let json = try JSONEncoder().encode([AnnotationColor.palette(.red)])
        #expect(String(decoding: json, as: UTF8.self) == #"["red"]"#)
    }

    @Test func sampledRoundTrips() throws {
        let color = AnnotationColor.sampled(RGBA(r: 39, g: 44, b: 53, a: 255))
        let data = try JSONEncoder().encode([color])
        #expect(try JSONDecoder().decode([AnnotationColor].self, from: data) == [color])
    }

    @Test func decodesV8Annotation() throws {
        let original = Annotation(
            id: 1, shape: .blur(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            color: .palette(.blue), width: .thin)
        // v8 wrote the palette name as a bare string; that is still the encoded shape.
        let data = try JSONEncoder().encode(original)
        #expect(String(decoding: data, as: UTF8.self).contains(#""color":"blue""#))
        let annotation = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(annotation.color == .palette(.blue))
    }

    @Test func sampledInkByLuminance() {
        let dark = AnnotationColor.sampled(RGBA(r: 0x27, g: 0x2C, b: 0x35, a: 255))
        let light = AnnotationColor.sampled(RGBA(r: 0xF0, g: 0xF0, b: 0xF0, a: 255))
        #expect(dark.contrastingInk == RGBA(r: 255, g: 255, b: 255, a: 255))
        #expect(light.contrastingInk == RGBA(r: 0, g: 0, b: 0, a: 255))
    }

    @Test func paletteDelegates() {
        #expect(AnnotationColor.palette(.yellow).rgba == Palette.yellow.rgba)
        #expect(AnnotationColor.palette(.yellow).contrastingInk == Palette.yellow.contrastingInk)
        #expect(AnnotationColor.initial == .palette(.initial))
    }
}
