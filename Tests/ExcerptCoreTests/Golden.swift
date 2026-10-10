import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ExcerptCore

/// Golden-image comparison. A missing golden, or `EXCERPT_RECORD_GOLDENS=1`, writes the image
/// to `Goldens/<name>.png` and fails the test so the new image is looked at before committing.
struct GoldenError: Error, CustomStringConvertible {
    let description: String
    static func writeFailed(_ path: String) -> GoldenError {
        GoldenError(description: "Could not write golden to \(path)")
    }
}

enum Golden {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Goldens")

    static func check(
        _ image: CGImage, named name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let url = directory.appendingPathComponent("\(name).png")
        let record = ProcessInfo.processInfo.environment["EXCERPT_RECORD_GOLDENS"] == "1"
        if record || !FileManager.default.fileExists(atPath: url.path) {
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw GoldenError.writeFailed(url.path) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw GoldenError.writeFailed(url.path)
            }
            Issue.record(
                "Recorded golden \(name).png: inspect it, then re-run",
                sourceLocation: sourceLocation)
            return
        }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let expected = PixelBuffer(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
        let actual = PixelBuffer(image)
        #expect(actual.width == expected.width, sourceLocation: sourceLocation)
        #expect(actual.height == expected.height, sourceLocation: sourceLocation)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        let differing = actual.fractionDiffering(from: expected, tolerance: 2)
        #expect(
            differing <= 0.001, "\(name): \(differing * 100)% of pixels differ",
            sourceLocation: sourceLocation)
    }
}
