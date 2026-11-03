import CoreGraphics
import Foundation

/// One run of text a recogniser found, with its bounds in the pixels of the image it read,
/// top-left origin.
public struct RecognizedText: Equatable, Sendable {
    public let string: String
    public let bounds: CGRect
    /// A barcode's payload at the code's bounds, not text drawn there: Capture Text reads it in
    /// place, the editor neither matches nor replaces it.
    public let isBarcode: Bool

    public init(_ string: String, _ bounds: CGRect, isBarcode: Bool = false) {
        self.string = string
        self.bounds = bounds
        self.isBarcode = isBarcode
    }
}

/// Reads the text in an image and returns its runs, bounds in the image's pixels, top-left
/// origin. The one seam between excerpt and an OCR engine, so everything around it is tested
/// without one.
public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage) throws -> [RecognizedText]
}
