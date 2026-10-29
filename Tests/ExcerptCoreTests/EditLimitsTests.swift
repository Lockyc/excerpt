import CoreGraphics
import Testing

@testable import ExcerptCore

@Suite struct EditLimitsTests {
    /// The app checks a capture it loaded before the editor renders it: a crafted
    /// master whose cuts render it past the limits, and larger than its original, is refused.
    @Test func aLoadedCaptureIsCheckedForTheSizeItRendersAt() throws {
        let cuts = stride(from: 0, to: 4000, by: 2).map {
            Cut(axis: .vertical, lower: $0, upper: $0 + 1)
        }
        let edits = EditDocument(scale: 3, cuts: cuts)
        let width = 2000 + 2000 * 54
        #expect(throws: EditLimitsError.rendersTooLarge("m.png", width: width, height: 2)) {
            try EditLimits.check("m.png", width: 4000, height: 2, edits: edits)
        }
        try EditLimits.check("m.png", width: 4000, height: 2, edits: EditDocument(scale: 3))
        let message = EditLimitsError.rendersTooLarge("m.png", width: width, height: 2).reason
        #expect(message.contains("renders at \(width)×2 pixels"))
    }

    /// An original past the limits — a crafted or huge PNG opened from Finder — is refused
    /// before the editor decodes it, edited or not.
    @Test func anOriginalPastTheLimitsIsRefused() throws {
        let plain = EditDocument(scale: 1)
        #expect(throws: EditLimitsError.tooManyPixels("p.png", width: 40_000, height: 40_000)) {
            try EditLimits.check("p.png", width: 40_000, height: 40_000, edits: plain)
        }
        let side = EditLimits.maximumSide + 1
        #expect(throws: EditLimitsError.tooManyPixels("p.png", width: side, height: 1)) {
            try EditLimits.check("p.png", width: side, height: 1, edits: plain)
        }
    }

    /// A render no larger than an original within the limits is let through, even at the limit.
    @Test func aRenderNoLargerThanItsOriginalIsLetThrough() throws {
        let (width, height) = (6_720, Stitcher.defaultMaximumHeight)
        try EditLimits.check("p.png", width: width, height: height, edits: EditDocument(scale: 2))
        let cropped = EditDocument(
            scale: 2, crop: PixelRect(x: 0, y: 0, width: width, height: height - 10))
        try EditLimits.check("p.png", width: width, height: height, edits: cropped)
    }

    @Test func aHugeMarginIsRefusedBeforeDrawing() {
        let far = Annotation(
            id: 1,
            shape: .text(
                origin: CGPoint(x: -EditDocument.coordinateLimit, y: 10), string: "x"))
        let edits = EditDocument(
            scale: 1, annotations: [far], marginColor: RGBA(r: 1, g: 2, b: 3, a: 255), salt: 1)
        #expect(throws: EditLimitsError.self) {
            try EditLimits.check("m.png", width: 100, height: 100, edits: edits)
        }
    }
}
