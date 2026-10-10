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

    /// The run of median height (the shorter of the two middle ones for an even count; the
    /// earlier on ties): the line's yardstick, which one tall or tiny outlier cannot move.
    var anchor: CGRect {
        let sorted = runs.map(\.bounds).sorted { $0.height < $1.height }
        return sorted[(sorted.count - 1) / 2]
    }
}

/// Recognised runs in reading order: top to bottom, and left to right along a line.
public enum ReadingOrder {
    /// Groups runs into lines. A run joins the current line when its vertical overlap with the
    /// line's anchor (its median-height run, so a tall outlier cannot chain two lines together)
    /// is at least half the smaller of the two heights; so a raised marker or a slightly offset
    /// baseline stays on its line. Lines run top to bottom, runs left to right. Runs with no
    /// text or non-finite bounds are dropped, and newlines inside a run become spaces. Columns
    /// are not segmented: a two-column layout reads row by row.
    public static func lines(_ runs: [RecognizedText]) -> [TextLine] {
        let ordered = runs.compactMap { run -> RecognizedText? in
            let b = run.bounds
            guard b.minX.isFinite, b.minY.isFinite, b.width.isFinite, b.height.isFinite,
                b.width >= 0, b.height >= 0
            else { return nil }
            let string = run.string.components(separatedBy: .newlines).joined(separator: " ")
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return RecognizedText(string, b)
        }
        .sorted { ($0.bounds.midY, $0.bounds.minX) < ($1.bounds.midY, $1.bounds.minX) }

        var lines: [TextLine] = []
        for run in ordered {
            if let last = lines.last {
                let anchor = last.anchor
                let overlap = min(anchor.maxY, run.bounds.maxY) - max(anchor.minY, run.bounds.minY)
                if overlap >= 0.5 * min(anchor.height, run.bounds.height) {
                    lines[lines.count - 1] = TextLine(runs: last.runs + [run])
                    continue
                }
            }
            lines.append(TextLine(runs: [run]))
        }
        return lines.map { TextLine(runs: $0.runs.sorted { $0.bounds.minX < $1.bounds.minX }) }
    }

    /// One line of text per line, written by `write`, with a blank line where the space above a
    /// line is taller than the previous line's median run height: a paragraph break.
    public static func text(
        _ lines: [TextLine], write: (TextLine) -> String = { $0.text }
    ) -> [String] {
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let previous = lines[index - 1]
                if line.bounds.minY - previous.bounds.maxY > previous.anchor.height {
                    out.append("")
                }
            }
            out.append(write(line))
        }
        return out
    }
}
