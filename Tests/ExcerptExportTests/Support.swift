import CoreGraphics
import ExcerptCore
import ExcerptExport
import ExcerptTestSupport

/// A recogniser that reads colour, not letters: each word of `palette` is painted as a solid
/// block of its colour, and a block is read wherever at least `minimumPixels` of exactly that
/// colour appear. A blur's averaged, noised blocks are never an exact palette colour, so a
/// blurred word is unreadable to it, as to a real recogniser.
struct ColourWords: TextRecognizer {
    static let palette: [(word: String, colour: RGBA)] = [
        ("alpha", RGBA(r: 200, g: 30, b: 30, a: 255)),
        ("beta", RGBA(r: 30, g: 160, b: 30, a: 255)),
        ("secret", RGBA(r: 30, g: 30, b: 200, a: 255)),
        ("cutaway", RGBA(r: 200, g: 120, b: 0, a: 255)),
        ("left", RGBA(r: 120, g: 0, b: 160, a: 255)),
        ("right", RGBA(r: 0, g: 140, b: 160, a: 255)),
        ("omega", RGBA(r: 90, g: 90, b: 20, a: 255)),
    ]
    static let white = RGBA(r: 255, g: 255, b: 255, a: 255)
    var minimumPixels = 50

    func recognize(_ image: CGImage) throws -> [RecognizedText] {
        let buffer = PixelBuffer(image)
        var boxes = [CGRect](repeating: .null, count: Self.palette.count)
        var counts = [Int](repeating: 0, count: Self.palette.count)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let i = (y * buffer.width + x) * 4
                let pixel = RGBA(
                    r: buffer.bytes[i], g: buffer.bytes[i + 1], b: buffer.bytes[i + 2],
                    a: buffer.bytes[i + 3])
                guard pixel != Self.white,
                    let word = Self.palette.firstIndex(where: { $0.colour == pixel })
                else { continue }
                counts[word] += 1
                boxes[word] = boxes[word].union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return Self.palette.indices.compactMap { word in
            counts[word] >= minimumPixels
                ? RecognizedText(Self.palette[word].word, boxes[word]) : nil
        }
    }

    /// A white page with each named word painted as a 60×10 block at its top-left point.
    static func page(width: Int, height: Int, words: [String: (x: Int, y: Int)]) -> CGImage {
        Fixtures.paint(width: width, height: height) { x, y in
            for (word, origin) in words
            where (origin.x..<(origin.x + 60)).contains(x)
                && (origin.y..<(origin.y + 10)).contains(y)
            {
                return palette.first { $0.word == word }!.colour
            }
            return white
        }
    }
}

/// Keeps every image it is shown, in order, and reads nothing.
final class RecordingRecognizer: TextRecognizer, @unchecked Sendable {
    private(set) var images: [CGImage] = []
    func recognize(_ image: CGImage) throws -> [RecognizedText] {
        images.append(image)
        return []
    }
}
