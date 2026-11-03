import CoreGraphics
import ExcerptCore
import Vision

/// Vision's accurate text recognition, on device, plus QR codes: a code's payload is a run at
/// the code's bounds, so it reads in place among the text. Language correction is off:
/// screenshots are full of identifiers, numbers and paths that correction would "fix". A Vision
/// failure throws; it is never an empty result. Vision has a `RecognizedText` of its own, so
/// Core's is named in full here.
public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    public func recognize(_ image: CGImage) throws -> [ExcerptCore.RecognizedText] {
        // The request revisions are the OS default on purpose: current accuracy.
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        codes.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([text, codes])
        let lines: [ExcerptCore.RecognizedText] = (text.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return ExcerptCore.RecognizedText(
                candidate.string, pixelRect(observation.boundingBox, image))
        }
        // A code with no string payload (binary data) has nothing to copy.
        let payloads: [ExcerptCore.RecognizedText] = (codes.results ?? []).compactMap {
            observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else {
                return nil
            }
            return ExcerptCore.RecognizedText(
                payload, pixelRect(observation.boundingBox, image), isBarcode: true)
        }
        return lines + payloads
    }

    private func pixelRect(_ box: CGRect, _ image: CGImage) -> CGRect {
        Self.pixelRect(normalized: box, width: image.width, height: image.height)
    }

    /// A Vision bounding box (normalised, bottom-left origin) in the image's pixels, top-left
    /// origin. The one place the two conventions meet.
    static func pixelRect(normalized box: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
            width: box.width * CGFloat(width), height: box.height * CGFloat(height))
    }
}
