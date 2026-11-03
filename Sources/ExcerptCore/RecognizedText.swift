import CoreGraphics
import Foundation

/// One run of text a recogniser found, with its bounds in the pixels of the image it read,
/// top-left origin.
public struct RecognizedText: Equatable, Sendable {
    public let string: String
    public let bounds: CGRect

    public init(_ string: String, _ bounds: CGRect) {
        self.string = string
        self.bounds = bounds
    }
}

/// Reads the text in an image and returns its runs, bounds in the image's pixels, top-left
/// origin. The one seam between excerpt and an OCR engine, so everything around it is tested
/// without one.
public protocol TextRecognizer: Sendable {
    func recognize(_ image: CGImage) throws -> [RecognizedText]
}
