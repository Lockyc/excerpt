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

/// A line of text: the runs that sit side by side, left to right.
public struct TextLine: Equatable, Sendable {
    public let runs: [RecognizedText]

    public var bounds: CGRect { runs.map(\.bounds).reduce(runs[0].bounds) { $0.union($1) } }
    public var text: String { runs.map(\.string).joined(separator: " ") }
}

/// Recognised runs in reading order: top to bottom, and left to right along a line.
public enum ReadingOrder {
    /// Groups runs into lines. A run joins the line above it when either one's middle lies within
    /// the other's height, so a small run beside a tall one shares its line but the next line
    /// down does not. Lines run top to bottom, runs left to right. Runs with no text are dropped.
    public static func lines(_ runs: [RecognizedText]) -> [TextLine] {
        var lines: [[RecognizedText]] = []
        let ordered = runs.filter { !$0.string.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.bounds.midY, $0.bounds.minX) < ($1.bounds.midY, $1.bounds.minX) }
        for run in ordered {
            if let last = lines.last {
                let bounds = last.map(\.bounds).reduce(last[0].bounds) { $0.union($1) }
                let inside =
                    (bounds.minY...bounds.maxY).contains(run.bounds.midY)
                    || (run.bounds.minY...run.bounds.maxY).contains(bounds.midY)
                if inside {
                    lines[lines.count - 1].append(run)
                    continue
                }
            }
            lines.append([run])
        }
        return lines.map { TextLine(runs: $0.sorted { $0.bounds.minX < $1.bounds.minX }) }
    }

    /// One line of text per line, written by `write`, with a blank line where the space above a
    /// line is taller than the line before it: a paragraph break.
    public static func text(
        _ lines: [TextLine], write: (TextLine) -> String = { $0.text }
    ) -> [String] {
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let previous = lines[index - 1].bounds
                if line.bounds.minY - previous.maxY > previous.height { out.append("") }
            }
            out.append(write(line))
        }
        return out
    }
}
