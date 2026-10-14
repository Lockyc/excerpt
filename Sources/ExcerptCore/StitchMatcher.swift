import Foundation

/// How the next frame of a scrolling capture relates to the previous one.
public enum FrameMatch: Equatable, Sendable {
    /// The page didn't move. Anything that changed is small and in place: a spinner, a caret.
    case still
    /// The content between the sticky rows moved up by `offset` rows. `header` rows at the top
    /// and `footer` rows at the bottom are the same in both frames.
    case moved(offset: Int, header: Int, footer: Int)
    /// No offset is convincing: the content changed as it moved (video, animation), more than a
    /// frame's height went past, or the frame shows something else.
    case uncertain
}

/// Finds the scroll offset between two frames of the same region from their row signatures.
public enum StitchMatcher {
    /// The share of evidence rows that must match for an offset to be believed.
    public static let confidenceThreshold = 0.8
    /// An offset with more than this many mismatching rows whose differing pixels span more than
    /// a quarter of the changed columns is different content, not animation, however high its
    /// share. It also halts an honest move with an animation wider than that, or several
    /// animations on the same rows: that fails safe as uncertain, never a wrong seam.
    public static let maximumContradictions = 2
    /// An offset is believed only if every other offset scores at least this much lower.
    public static let ambiguityMargin = 0.02
    /// Fewer row pairs carrying evidence than this and an offset is not scored at all.
    public static let minimumEvidenceRows = 8
    /// Width of the right-edge strip left out of matching, in points: an overlay scroll bar's
    /// thumb sits there and moves with every step, unlike the content beside it.
    public static let scrollBarPoints = 16.0

    /// The right-edge columns left out of matching for a region `width` pixels wide: the scroll
    /// bar strip at `scale`, never more than an eighth of the width.
    public static func ignoredRightColumns(width: Int, scale: Double) -> Int {
        max(0, min(Int((scrollBarPoints * scale).rounded()), width / 8))
    }

    public static func match(
        _ previous: PixelBuffer, _ next: PixelBuffer, ignoringRightColumns ignored: Int
    ) -> FrameMatch {
        guard previous.width == next.width, previous.height == next.height, previous.width > 0,
            previous.height > 0
        else { return .uncertain }
        let height = previous.height
        let width = previous.width - min(max(0, ignored), previous.width - 1)
        guard let span = changedColumns(previous, next, width: width) else { return .still }

        // In place: the whole width, every row. Unchanged sticky rows and a static page around a
        // small animation all count for it.
        let wholePrevious = RowSignatures(previous, columns: 0..<width)
        let wholeNext = RowSignatures(next, columns: 0..<width)
        let stillScore = score(
            wholePrevious, wholeNext, previousStart: 0, nextStart: 0, count: height,
            previousUnique: uniqueRows(wholePrevious, in: 0..<height),
            nextUnique: uniqueRows(wholeNext, in: 0..<height))

        // Moved: only the columns that changed (a static sidebar beside a scrolling pane says
        // nothing about the offset), and only the rows between the sticky bars.
        let wholeSpan = span == 0..<width
        let a = wholeSpan ? wholePrevious : RowSignatures(previous, columns: span)
        let b = wholeSpan ? wholeNext : RowSignatures(next, columns: span)
        var header = 0
        while header < height && a.hashes[header] == b.hashes[header] { header += 1 }
        var footer = 0
        while footer < height - header
            && a.hashes[height - 1 - footer] == b.hashes[height - 1 - footer]
        {
            footer += 1
        }
        let content = height - header - footer
        let contentRows = header..<(header + content)
        let uniqueA = uniqueRows(a, in: contentRows)
        let uniqueB = uniqueRows(b, in: contentRows)
        var best: (offset: Int, score: Double)?
        var runnerUp = -1.0
        if content > 1 {
            for offset in 1..<content {
                guard
                    let s = score(
                        a, b, previousStart: header + offset, nextStart: header,
                        count: content - offset, previousUnique: uniqueA, nextUnique: uniqueB)
                else { continue }
                if let current = best, s <= current.score {
                    runnerUp = max(runnerUp, s)
                } else {
                    runnerUp = max(runnerUp, best?.score ?? -1)
                    best = (offset, s)
                }
            }
        }

        if let stillScore, stillScore >= confidenceThreshold,
            stillScore >= (best?.score ?? 0) - ambiguityMargin
        {
            return .still
        }
        guard let best, best.score >= confidenceThreshold, runnerUp < best.score - ambiguityMargin
        else {
            return isCaretSized(span, rows: changedRows(wholePrevious, wholeNext), of: previous)
                ? .still : .uncertain
        }
        let contradictions = contradictions(
            previous, next, columns: span, previousStart: header + best.offset,
            nextStart: header, count: content - best.offset, previousUnique: uniqueA,
            nextUnique: uniqueB)
        guard contradictions <= maximumContradictions else { return .uncertain }
        return .moved(offset: best.offset, header: header, footer: footer)
    }

    /// The share of row pairs that match, pairing `previous` row `previousStart + i` with `next`
    /// row `nextStart + i`; nil when fewer than `minimumEvidenceRows` pairs are evidence.
    static func score(
        _ previous: RowSignatures, _ next: RowSignatures, previousStart: Int, nextStart: Int,
        count: Int, previousUnique: [Bool], nextUnique: [Bool]
    ) -> Double? {
        let (matches, evidence) = counts(
            previous, next, previousStart: previousStart, nextStart: nextStart, count: count,
            previousUnique: previousUnique, nextUnique: nextUnique)
        guard evidence >= minimumEvidenceRows else { return nil }
        return Double(matches) / Double(evidence)
    }

    /// Matching pairs and evidence pairs. A row is evidence only if its signature is unique within
    /// its frame's span: blank rows and rows that repeat match at many offsets, so they can't pin
    /// one.
    static func counts(
        _ previous: RowSignatures, _ next: RowSignatures, previousStart: Int, nextStart: Int,
        count: Int, previousUnique: [Bool], nextUnique: [Bool]
    ) -> (matches: Int, evidence: Int) {
        var matches = 0
        var evidence = 0
        for i in 0..<count {
            let p = previousStart + i
            let n = nextStart + i
            guard previousUnique[p], nextUnique[n] else { continue }
            let same = previous.hashes[p] == next.hashes[n]
            if same && previous.uniform[p] && next.uniform[n] { continue }
            evidence += 1
            if same { matches += 1 }
        }
        return (matches, evidence)
    }

    /// Evidence row pairs that differ across more than a quarter of `columns`. An animation or a
    /// caret differs in a patch; text that differs across the width is other content.
    static func contradictions(
        _ previous: PixelBuffer, _ next: PixelBuffer, columns: Range<Int>, previousStart: Int,
        nextStart: Int, count: Int, previousUnique: [Bool], nextUnique: [Bool]
    ) -> Int {
        var found = 0
        previous.bytes.withUnsafeBytes { pa in
            next.bytes.withUnsafeBytes { pb in
                for i in 0..<count {
                    let p = previousStart + i
                    let n = nextStart + i
                    guard previousUnique[p], nextUnique[n] else { continue }
                    var first = Int.max
                    var last = -1
                    for x in columns {
                        let u = pa.loadUnaligned(
                            fromByteOffset: (p * previous.width + x) * 4, as: UInt32.self)
                        let v = pb.loadUnaligned(
                            fromByteOffset: (n * next.width + x) * 4, as: UInt32.self)
                        if u != v {
                            first = min(first, x)
                            last = x
                        }
                    }
                    if last >= 0 && (last - first + 1) * 4 > columns.count { found += 1 }
                }
            }
        }
        return found
    }

    /// Which rows of `rows` have a signature no other row of `rows` shares; rows outside it are
    /// false.
    static func uniqueRows(_ signatures: RowSignatures, in rows: Range<Int>) -> [Bool] {
        var seen: [UInt64: Int] = [:]
        for y in rows { seen[signatures.hashes[y], default: 0] += 1 }
        var unique = [Bool](repeating: false, count: signatures.hashes.count)
        for y in rows { unique[y] = seen[signatures.hashes[y]] == 1 }
        return unique
    }

    /// The rows from the first to the last whose signatures differ; empty when none do.
    static func changedRows(_ a: RowSignatures, _ b: RowSignatures) -> Range<Int> {
        let changed = a.hashes.indices.filter { a.hashes[$0] != b.hashes[$0] }
        guard let first = changed.first, let last = changed.last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// Whether the change fits a blinking caret: confined to a narrow patch under half a percent
    /// of the frame. A frame too blank to score still shows the caret and nothing more.
    static func isCaretSized(_ columns: Range<Int>, rows: Range<Int>, of frame: PixelBuffer)
        -> Bool
    {
        columns.count * 4 <= frame.width
            && Double(columns.count * rows.count) <= 0.005 * Double(frame.width * frame.height)
    }

    /// The span from the leftmost to the rightmost column (below `width`) where the frames
    /// differ; nil when they don't.
    static func changedColumns(_ a: PixelBuffer, _ b: PixelBuffer, width: Int) -> Range<Int>? {
        var low = width
        var high = -1
        a.bytes.withUnsafeBytes { pa in
            b.bytes.withUnsafeBytes { pb in
                for y in 0..<a.height {
                    let rowStart = y * a.width * 4
                    // Most rows of a still page are identical: one compare clears them.
                    if memcmp(pa.baseAddress! + rowStart, pb.baseAddress! + rowStart, width * 4)
                        == 0
                    {
                        continue
                    }
                    func differs(_ x: Int) -> Bool {
                        pa.loadUnaligned(fromByteOffset: rowStart + x * 4, as: UInt32.self)
                            != pb.loadUnaligned(fromByteOffset: rowStart + x * 4, as: UInt32.self)
                    }
                    var x = 0
                    while x < low && !differs(x) { x += 1 }
                    if x < low { low = x }
                    var r = width - 1
                    while r > high && !differs(r) { r -= 1 }
                    if r > high { high = r }
                }
            }
        }
        return high >= low ? low..<(high + 1) : nil
    }
}
