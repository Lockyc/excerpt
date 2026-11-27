import CoreGraphics
import CoreML
import ExcerptCore
import Vision
import os

/// Vision's accurate text recognition, on device, plus QR codes: a code's payload is a run at
/// the code's bounds, so it reads in place among the text. Language correction is off:
/// screenshots are full of identifiers, numbers and paths that correction would "fix". A Vision
/// failure throws; it is never an empty result. Vision has a `RecognizedText` of its own, so
/// Core's is named in full here.
public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    /// Set once the default compute devices have failed where the CPU succeeded: they stay
    /// broken for the rest of the process. Vision loads its compiled Neural Engine model from
    /// the app's Caches folder, and once macOS purges that folder under disk pressure every
    /// later request fails with an E5RT error until the app restarts. The CPU path does not
    /// load that bundle.
    private static let cpuOnly = OSAllocatedUnfairLock(initialState: false)

    public func recognize(_ image: CGImage) throws -> [ExcerptCore.RecognizedText] {
        if Self.cpuOnly.withLock({ $0 }) { return try recognize(image, onCPU: true) }
        do {
            return try recognize(image, onCPU: false)
        } catch {
            // The CPU's own failure would hide the cause, so the first error is the one thrown.
            guard let lines = try? recognize(image, onCPU: true) else { throw error }
            Self.cpuOnly.withLock { $0 = true }
            Log.capture.error(
                "text recognition moved to the CPU: \(Log.describe(error), privacy: .public)")
            return lines
        }
    }

    private func recognize(_ image: CGImage, onCPU: Bool) throws -> [ExcerptCore.RecognizedText] {
        // The request revisions are the OS default on purpose: current accuracy.
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        let codes = VNDetectBarcodesRequest()
        codes.symbologies = [.qr]
        if onCPU { try [text, codes].forEach(Self.runOnCPU) }
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

    private static func runOnCPU(_ request: VNRequest) throws {
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
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
