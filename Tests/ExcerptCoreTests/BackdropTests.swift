import Testing

@testable import ExcerptCore

@Suite struct BackdropTests {
    @Test func padsWithTheColourAndCentresTheImage() {
        let image = Fixtures.rowStripes(width: 30, height: 20)
        let grey = RGBA(r: 229, g: 229, b: 234, a: 255)
        let out = PixelBuffer(Backdrop.compose(image, padding: 10, color: grey))
        #expect(out.width == 50 && out.height == 40)
        #expect(out[x: 0, y: 0] == grey)
        #expect(out[x: 49, y: 39] == grey)
        #expect(out[x: 10, y: 10] == Fixtures.rowColor(0))
        #expect(out[x: 25, y: 29] == Fixtures.rowColor(19))
    }

    @Test func negativePaddingIsTreatedAsZero() {
        let image = Fixtures.rowStripes(width: 30, height: 20)
        let out = Backdrop.compose(image, padding: -5, color: RGBA(r: 1, g: 2, b: 3, a: 255))
        #expect(out.width == 30 && out.height == 20)
    }
}
