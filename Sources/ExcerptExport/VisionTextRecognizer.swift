import CoreGraphics
import Vision

/// Vision's accurate text recognition, on device. Language correction is off: screenshots are
/// full of identifiers, numbers and paths that correction would "fix". A Vision failure throws;
/// it is never an empty result.
public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    public func recognize(_ image: CGImage) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText(
                candidate.string,
                Self.pixelRect(
                    normalized: observation.boundingBox, width: image.width, height: image.height
                ))
        }
    }

    /// A Vision bounding box (normalised, bottom-left origin) in the image's pixels, top-left
    /// origin. The one place the two conventions meet.
    static func pixelRect(normalized box: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
            width: box.width * CGFloat(width), height: box.height * CGFloat(height))
    }
}
