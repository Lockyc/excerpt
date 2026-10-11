import CoreGraphics
import ExcerptTestSupport
import Testing

@testable import ExcerptCore

@Suite struct BackdropTests {
    let red = RGBA(r: 220, g: 40, b: 40, a: 255)
    let blue = RGBA(r: 40, g: 60, b: 220, a: 255)

    @Test func padsWithTheColourAndCentresTheImage() {
        let image = Fixtures.rowStripes(width: 30, height: 20)
        let grey = RGBA(r: 229, g: 229, b: 234, a: 255)
        let out = PixelBuffer(Backdrop.compose(image, padding: 10, fill: .color(grey)))
        #expect(out.width == 50 && out.height == 40)
        #expect(out[x: 0, y: 0] == grey)
        #expect(out[x: 49, y: 39] == grey)
        #expect(out[x: 10, y: 10] == Fixtures.rowColor(0))
        #expect(out[x: 25, y: 29] == Fixtures.rowColor(19))
    }

    @Test func negativePaddingIsTreatedAsZero() {
        let image = Fixtures.rowStripes(width: 30, height: 20)
        let out = Backdrop.compose(
            image, padding: -5, fill: .color(RGBA(r: 1, g: 2, b: 3, a: 255)))
        #expect(out.width == 30 && out.height == 20)
    }

    @Test func aspectFillCoversTheCanvasAndCentres() {
        #expect(
            Backdrop.aspectFill(
                CGSize(width: 200, height: 100), into: CGSize(width: 50, height: 50))
                == CGRect(x: -25, y: 0, width: 100, height: 50))
        #expect(
            Backdrop.aspectFill(
                CGSize(width: 100, height: 200), into: CGSize(width: 100, height: 100))
                == CGRect(x: 0, y: -50, width: 100, height: 200))
        #expect(
            Backdrop.aspectFill(CGSize(width: 10, height: 10), into: CGSize(width: 40, height: 20))
                == CGRect(x: 0, y: -10, width: 40, height: 40))
    }

    @Test func wallpaperFillsThePaddingAndKeepsTheImageExact() {
        // Left half red, right half blue: aspect-fill keeps both halves either side of centre.
        let wallpaper = Fixtures.paint(width: 400, height: 200) { x, _ in x < 200 ? red : blue }
        let image = Fixtures.rowStripes(width: 30, height: 20)
        let out = PixelBuffer(Backdrop.compose(image, padding: 40, fill: .image(wallpaper)))
        #expect(out.width == 110 && out.height == 100)
        #expect(out[x: 0, y: 0] == red)
        #expect(out[x: 109, y: 0] == blue)
        #expect(out[x: 40, y: 40] == Fixtures.rowColor(0))
        #expect(out[x: 69, y: 59] == Fixtures.rowColor(19))
    }

    @Test func wallpaperCastsAShadowBelowTheImage() {
        let wallpaper = Fixtures.paint(width: 100, height: 100) { _, _ in red }
        let image = Fixtures.rowStripes(width: 60, height: 40)
        let out = PixelBuffer(Backdrop.compose(image, padding: 40, fill: .image(wallpaper)))
        let underneath = out[x: 70, y: 40 + 40 + 6]
        #expect(underneath.r < red.r - 20)
        #expect(out[x: 0, y: 0] == red)
    }

    @Test func wallpaperGolden() throws {
        let wallpaper = Fixtures.paint(width: 320, height: 200) { x, y in
            RGBA(r: UInt8(60 + x / 2), g: UInt8(80 + y / 2), b: 200, a: 255)
        }
        // A window with transparent corners, as ScreenCaptureKit returns one.
        let image = Fixtures.paint(width: 120, height: 80) { x, y in
            let corner = (x < 3 || x > 116) && (y < 3 || y > 76)
            return corner ? RGBA(r: 0, g: 0, b: 0, a: 0) : Fixtures.rowColor(y)
        }
        try Golden.check(
            Backdrop.compose(image, padding: 32, fill: .image(wallpaper)),
            named: "backdrop-wallpaper")
    }
}
