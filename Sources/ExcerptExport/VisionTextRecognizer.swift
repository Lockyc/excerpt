import CoreGraphics
import ExcerptCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import os

/// Vision's accurate text recognition, on device, plus QR codes: a code's payload is a run at
/// the code's bounds, so it reads in place among the text. Language correction is off:
/// screenshots are full of identifiers, numbers and paths that correction would "fix". A Vision
/// failure throws; it is never an empty result. Vision has a `RecognizedText` of its own, so
/// Core's is named in full here.
///
/// Vision compiles its model into the process's Caches folder and keeps a handle to those files
/// for each compute device and revision it has used. Once they are deleted from under a running
/// process, every one of those handles fails with an E5RT error for the rest of its life, and
/// nothing public reloads them. A fresh process reads clean, so with a `child` executable a
/// failed read is retried in one, and every later read goes to a fresh child.
public struct VisionTextRecognizer: TextRecognizer {
    /// Run with `childArgument`, it reads one image in a fresh process: `serveChild`.
    let child: URL?

    public init(child: URL? = nil) {
        self.child = child
    }

    /// The argument that makes an executable serve one read and exit.
    public static let childArgument = "--recognize"

    /// Set once an in-process read has failed where a child succeeded: this process's model
    /// handles stay broken until it quits.
    private static let inProcessBroken = OSAllocatedUnfairLock(initialState: false)

    public func recognize(_ image: CGImage) throws -> [ExcerptCore.RecognizedText] {
        guard let child else { return try Self.read(image) }
        if Self.inProcessBroken.withLock({ $0 }) { return try Self.read(image, in: child) }
        do {
            return try Self.read(image)
        } catch {
            // The child's own failure would hide the cause, so the first error is the one thrown.
            guard let lines = try? Self.read(image, in: child) else { throw error }
            Self.inProcessBroken.withLock { $0 = true }
            Log.capture.error(
                "text recognition moved to a child process: \(Log.describe(error), privacy: .public)"
            )
            return lines
        }
    }

    static func read(_ image: CGImage) throws -> [ExcerptCore.RecognizedText] {
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

    // MARK: The child process

    /// A child's read failed: its exit status and what it wrote to stderr.
    struct ChildFailed: Error, CustomStringConvertible {
        let status: Int32
        let message: String
        var description: String { "child exited \(status): \(message)" }
    }

    /// One run on the wire between parent and child.
    private struct Run: Codable {
        let string: String
        let x, y, width, height: Double
        let isBarcode: Bool
    }

    /// The image goes to the child as a PNG on stdin; its runs come back as JSON on stdout.
    static func read(_ image: CGImage, in child: URL) throws -> [ExcerptCore.RecognizedText] {
        let process = Process()
        process.executableURL = child
        process.arguments = [childArgument]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // stderr drains on a thread of its own, so a chatty child never blocks on a full pipe. Not
        // a dispatch queue: a caller blocking every pool thread would starve it.
        let stderr = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        Thread {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            stderr.withLock { $0 = data }
            drained.signal()
        }.start()
        try input.fileHandleForWriting.write(contentsOf: png(image))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()
        guard process.terminationStatus == 0 else {
            throw ChildFailed(
                status: process.terminationStatus,
                message: String(decoding: stderr.withLock { $0 }, as: UTF8.self))
        }
        return try JSONDecoder().decode([Run].self, from: data).map {
            ExcerptCore.RecognizedText(
                $0.string, CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                isBarcode: $0.isBarcode)
        }
    }

    /// The child's side: reads the PNG on stdin, writes its runs to stdout, and returns the exit
    /// status, with any failure described on stderr.
    public static func serveChild() -> Int32 {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                FileHandle.standardError.write(Data("no image on stdin".utf8))
                return 2
            }
            let runs = try read(image).map {
                Run(
                    string: $0.string, x: $0.bounds.minX, y: $0.bounds.minY,
                    width: $0.bounds.width, height: $0.bounds.height, isBarcode: $0.isBarcode)
            }
            FileHandle.standardOutput.write(try JSONEncoder().encode(runs))
            return 0
        } catch {
            FileHandle.standardError.write(Data(Log.describe(error).utf8))
            return 1
        }
    }

    private static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func pixelRect(_ box: CGRect, _ image: CGImage) -> CGRect {
        pixelRect(normalized: box, width: image.width, height: image.height)
    }

    /// A Vision bounding box (normalised, bottom-left origin) in the image's pixels, top-left
    /// origin. The one place the two conventions meet.
    static func pixelRect(normalized box: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
            width: box.width * CGFloat(width), height: box.height * CGFloat(height))
    }
}
