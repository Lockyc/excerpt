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
    /// Whether the background changes across `gutter` (columns) over `rows`, in the pixels the
    /// runs' bounds are in.
    public typealias BackgroundChange = (_ gutter: Range<Int>, _ rows: Range<Int>) -> Bool

    /// Two sides of a gutter line up, and so read as one table, when at least this fraction of
    /// the side with fewer lines has a partner on the other side…
    static let alignedFraction = 0.8
    /// …whose middle is within this fraction of the shorter line's height of its own.
    static let alignmentTolerance = 0.2

    /// The runs as blocks of lines, each block read whole before the next. A block splits into
    /// panes, left then right, at a gutter — a vertical gap no run crosses, at least the median
    /// run height wide — when `backgroundChanges` across it and the lines either side don't line
    /// up row for row. One that can't is cut at its tallest gap no run crosses horizontally and
    /// each half is tried again, so a bar across the top doesn't hold two panes below it
    /// together; when neither half splits, the block stays whole. So a menu over a
    /// terminal, or a tinted sidebar, reads pane by pane, while a table keeps its rows — even
    /// with a shaded first column — and panes on one background read row by row.
    public static func blocks(
        _ runs: [RecognizedText], backgroundChanges: BackgroundChange
    ) -> [[TextLine]] {
        split(cleaned(runs), backgroundChanges).map(group)
    }

    static func split(
        _ runs: [RecognizedText], _ backgroundChanges: BackgroundChange
    ) -> [[RecognizedText]] {
        guard !runs.isEmpty else { return [] }
        if let (left, right) = panes(runs, backgroundChanges) {
            return split(left, backgroundChanges) + split(right, backgroundChanges)
        }
        guard let (upper, lower) = bands(runs) else { return [runs] }
        let above = split(upper, backgroundChanges)
        let below = split(lower, backgroundChanges)
        return above.count == 1 && below.count == 1 ? [runs] : above + below
    }

    /// The first gutter, widest first, that `runs` split at into two panes.
    static func panes(
        _ runs: [RecognizedText], _ backgroundChanges: BackgroundChange
    ) -> ([RecognizedText], [RecognizedText])? {
        let heights = runs.map(\.bounds.height).sorted()
        let minimumWidth = heights[(heights.count - 1) / 2]
        let byX = runs.sorted { $0.bounds.minX < $1.bounds.minX }
        var gutters: [(from: CGFloat, to: CGFloat)] = []
        var reach = byX[0].bounds.maxX
        for run in byX.dropFirst() {
            if run.bounds.minX - reach >= minimumWidth { gutters.append((reach, run.bounds.minX)) }
            reach = max(reach, run.bounds.maxX)
        }
        let top = runs.map(\.bounds.minY).min()!
        let bottom = runs.map(\.bounds.maxY).max()!
        let rows = Int(top.rounded(.down))..<Int(bottom.rounded(.up))
        for gutter in gutters.sorted(by: { $0.to - $0.from > $1.to - $1.from }) {
            let left = runs.filter { $0.bounds.maxX <= gutter.from }
            let right = runs.filter { $0.bounds.maxX > gutter.from }
            let columns = Int(gutter.from.rounded(.up))..<Int(gutter.to.rounded(.down))
            if !lineUp(group(left), group(right)), backgroundChanges(columns, rows) {
                return (left, right)
            }
        }
        return nil
    }

    /// Whether two sides' lines pair off row for row, as a table's columns do.
    static func lineUp(_ a: [TextLine], _ b: [TextLine]) -> Bool {
        let (few, many) = a.count <= b.count ? (a, b) : (b, a)
        let partnered = few.filter { line in
            many.contains { other in
                abs(line.anchor.midY - other.anchor.midY)
                    <= alignmentTolerance * min(line.anchor.height, other.anchor.height)
            }
        }
        return Double(partnered.count) >= alignedFraction * Double(few.count)
    }

    /// `runs` above and below the tallest gap no run crosses (the topmost of equals), or nil
    /// when every row holds a run. The tallest first, so a pane's own line spacing doesn't cut
    /// it up before the gap under a bar does.
    static func bands(_ runs: [RecognizedText]) -> ([RecognizedText], [RecognizedText])? {
        let byY = runs.sorted { $0.bounds.minY < $1.bounds.minY }
        var bottom = byY[0].bounds.maxY
        var cut: (at: Int, height: CGFloat)?
        for (index, run) in byY.enumerated().dropFirst() {
            let gap = run.bounds.minY - bottom
            if gap > 0, gap > cut?.height ?? 0 { cut = (index, gap) }
            bottom = max(bottom, run.bounds.maxY)
        }
        guard let cut else { return nil }
        return (Array(byY[..<cut.at]), Array(byY[cut.at...]))
    }

    /// Each block's lines as `text` writes them, with a blank line between blocks.
    public static func text(
        blocks: [[TextLine]], write: (TextLine) -> String = { $0.text }
    ) -> [String] {
        Array(blocks.map { text($0, write: write) }.joined(separator: [""]))
    }

    /// Groups runs into lines. A run joins the current line when its vertical overlap with the
    /// line's anchor (its median-height run, so a tall outlier cannot chain two lines together)
    /// is at least half the smaller of the two heights; so a raised marker or a slightly offset
    /// baseline stays on its line. Lines run top to bottom, runs left to right. Runs with no
    /// text or non-finite bounds are dropped, and newlines inside a run become spaces. Columns
    /// are not split here; `blocks` splits panes first.
    public static func lines(_ runs: [RecognizedText]) -> [TextLine] {
        group(cleaned(runs))
    }

    /// `runs` with every run `lines` would drop removed and newlines turned into spaces.
    static func cleaned(_ runs: [RecognizedText]) -> [RecognizedText] {
        runs.compactMap { run -> RecognizedText? in
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
    }

    /// Cleaned runs grouped into lines, as `lines` describes.
    static func group(_ runs: [RecognizedText]) -> [TextLine] {
        let ordered = runs.sorted {
            ($0.bounds.midY, $0.bounds.minX) < ($1.bounds.midY, $1.bounds.minX)
        }
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
