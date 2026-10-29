import Foundation

/// How the next frame of a scrolling capture relates to the previous one.
public enum FrameMatch: Equatable, Sendable {
    /// The page didn't move. Anything that changed is small and in place: a spinner, a caret.
    case still
    /// The content in `columns` (the scrolling band) moved up by `offset` rows; `header` rows at
    /// the top and `footer` rows at the bottom of the band are the same in both frames, or covered
    /// by something that stays in place over the page there (`StitchMatcher.overlayRows`). Columns
    /// outside the band didn't scroll with it: margins, or side panels fixed in place or moving
    /// by another amount.
    case moved(offset: Int, header: Int, footer: Int, columns: Range<Int>)
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
    /// Strips the changed columns are split into when they don't move as one, to find the band
    /// that does.
    public static let strips = 16
    /// The narrowest strip: narrower, too few of a strip's rows differ for any to be evidence.
    public static let minimumStripWidth = 32
    /// The narrowest scrolling band believed, as a share of the frame's width: narrower, a strip
    /// of content beside something animated could alias an offset.
    public static let minimumBandShare = 1.0 / 3
    /// The pinned-bar headers tried when the frames' shared header doesn't explain a move.
    public static let pinnedCandidates = 4
    /// The most of the frame's height, above the footer, that something staying in place over
    /// the page may cover when the plain move doesn't convince: those rows count as footer.
    public static let maximumOverlayShare = 0.25

    /// The right-edge columns left out of matching for a region `width` pixels wide: the scroll
    /// bar strip at `scale`, never more than an eighth of the width.
    public static func ignoredRightColumns(width: Int, scale: Double) -> Int {
        max(0, min(Int((scrollBarPoints * scale).rounded()), width / 8))
    }

    /// How far a pixel may sit from `previous`'s commonest colour, in levels on every channel, and
    /// still be background when the frames match no other way: a faint wallpaper fixed behind the
    /// page (a chat app's doodles) doesn't scroll with it, so every row it shows through differs
    /// at the page's true offset.
    public static let faintLevels = 16

    /// The frames as they are, failing that with faint pixels taken as background
    /// (`faintLevels`). Rows are matched, never copied, from the flattened frames: the stitch
    /// keeps each frame's own pixels.
    public static func match(
        _ previous: PixelBuffer, _ next: PixelBuffer, ignoringRightColumns ignored: Int
    ) -> FrameMatch {
        let plain = matchPixels(previous, next, ignoringRightColumns: ignored)
        guard plain == .uncertain, let background = background(previous) else { return plain }
        return matchPixels(
            flattened(previous, toward: background), flattened(next, toward: background),
            ignoringRightColumns: ignored)
    }

    /// The frame's commonest colour over every fourth row and column; nil for an empty frame.
    static func background(_ frame: PixelBuffer) -> UInt32? {
        var counts: [UInt32: Int] = [:]
        frame.bytes.withUnsafeBytes { raw in
            for y in stride(from: 0, to: frame.height, by: 4) {
                for x in stride(from: 0, to: frame.width, by: 4) {
                    counts[
                        raw.loadUnaligned(
                            fromByteOffset: (y * frame.width + x) * 4, as: UInt32.self),
                        default: 0] += 1
                }
            }
        }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    /// `frame` with every pixel within `faintLevels` of `background` on each channel set to it.
    static func flattened(_ frame: PixelBuffer, toward background: UInt32) -> PixelBuffer {
        var out = frame
        out.bytes.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4) {
                let pixel = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)
                raw.storeBytes(
                    of: flat(pixel, toward: background), toByteOffset: i, as: UInt32.self)
            }
        }
        return out
    }

    /// `background` when `pixel` is within `faintLevels` of it on each colour channel, else
    /// `pixel`: one pixel of `flattened`.
    @inline(__always)
    static func flat(_ pixel: UInt32, toward background: UInt32) -> UInt32 {
        for shift in stride(from: UInt32(0), to: 24, by: 8) {
            let a = Int(pixel >> shift & 0xFF)
            let b = Int(background >> shift & 0xFF)
            if abs(a - b) > faintLevels { return pixel }
        }
        return background
    }

    static func matchPixels(
        _ previous: PixelBuffer, _ next: PixelBuffer, ignoringRightColumns ignored: Int
    ) -> FrameMatch {
        guard previous.width == next.width, previous.height == next.height, previous.width > 0,
            previous.height > 0
        else { return .uncertain }
        let height = previous.height
        let width = previous.width - min(max(0, ignored), previous.width - 1)
        guard let changed = changedColumns(previous, next, width: width) else { return .still }
        let span = withoutScrollThumb(changed, previous, next, widest: ignored)

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
        let whole = candidate(a, b, height: height)
        if let stillScore, stillScore >= confidenceThreshold,
            stillScore >= (whole.best?.score ?? 0) - ambiguityMargin
        {
            return .still
        }
        if let moved = believed(whole, previous, next, columns: span, a: a, b: b) { return moved }
        for pinned in pinnedHeaders(a, b, after: whole.header, height: height) {
            let c = candidate(a, b, height: height, header: pinned.end)
            if let best = c.best, best.offset > pinned.shift,
                let moved = believed(c, previous, next, columns: span, a: a, b: b)
            {
                return moved
            }
        }
        if let moved = band(previous, next, span: span, width: width) { return moved }
        if !whole.convincing,
            isCaretSized(span, rows: changedRows(wholePrevious, wholeNext), of: previous)
        {
            return .still
        }
        return .uncertain
    }

    /// The best offset of the rows between the sticky bars, scored over one column range.
    struct Candidate {
        let header: Int
        let footer: Int
        let best: (offset: Int, score: Double)?
        let runnerUp: Double
        let uniqueA: [Bool]
        let uniqueB: [Bool]
        /// Scored with an overlay limit: `footer` includes the rows the best offset left out.
        var overlaid = false

        /// The best offset clears the confidence threshold, clearly ahead of the others.
        var convincing: Bool {
            guard let best else { return false }
            return best.score >= StitchMatcher.confidenceThreshold
                && runnerUp < best.score - StitchMatcher.ambiguityMargin
        }
    }

    /// `header`, when given, is taken as the sticky rows at the top instead of the rows the two
    /// frames share there. With an `overlayLimit`, each offset may leave out up to that many rows
    /// at its overlap's end (`overlayRows`), and they join the footer.
    static func candidate(
        _ a: RowSignatures, _ b: RowSignatures, height: Int, header given: Int? = nil,
        overlayLimit: Int = 0
    ) -> Candidate {
        var header = given ?? 0
        if given == nil {
            while header < height && a.hashes[header] == b.hashes[header] { header += 1 }
        }
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
        var bestOverlay = 0
        var runnerUp = -1.0
        if content > 1 {
            for offset in 1..<content {
                let overlay = overlayRows(
                    a, b, start: header, offset: offset, count: content - offset,
                    limit: overlayLimit, uniqueA: uniqueA, uniqueB: uniqueB)
                guard
                    let s = score(
                        a, b, previousStart: header + offset, nextStart: header,
                        count: content - offset - overlay, previousUnique: uniqueA,
                        nextUnique: uniqueB)
                else { continue }
                if let current = best, s <= current.score {
                    runnerUp = max(runnerUp, s)
                } else {
                    runnerUp = max(runnerUp, best?.score ?? -1)
                    best = (offset, s)
                    bestOverlay = overlay
                }
            }
        }
        return Candidate(
            header: header, footer: footer + bestOverlay, best: best, runnerUp: runnerUp,
            uniqueA: uniqueA, uniqueB: uniqueB, overlaid: overlayLimit > 0)
    }

    /// The rows at the end of an offset's overlap, above the footer, that it doesn't explain:
    /// `a`'s bottom rows where something that stays in place (a floating button, a composer, a
    /// fade above a footer) covers the page that `b` shows uncovered `offset` rows higher. From
    /// the topmost evidence pair that differs among the last `limit` rows, since the element may
    /// float clear of the footer; 0 when none differs.
    static func overlayRows(
        _ a: RowSignatures, _ b: RowSignatures, start: Int, offset: Int, count: Int, limit: Int,
        uniqueA: [Bool], uniqueB: [Bool]
    ) -> Int {
        for i in max(0, count - limit)..<max(0, count) {
            let p = start + offset + i
            let n = start + i
            if uniqueA[p] && uniqueB[n] && a.hashes[p] != b.hashes[n] { return count - i }
        }
        return 0
    }

    /// Where `b`'s header could end if a bar from the page's flow pinned under the sticky
    /// `header` during the move: `b`'s rows from `header` on are `a`'s from `header + shift`, for
    /// at least `minimumEvidenceRows` rows that aren't blank. The bar scrolled `shift` rows before
    /// it stuck, so the page's own offset must be larger: the page's content matches the same way
    /// at its offset. The `pinnedCandidates` longest, on a tie the smallest shift first.
    static func pinnedHeaders(
        _ a: RowSignatures, _ b: RowSignatures, after header: Int, height: Int
    ) -> [(end: Int, shift: Int)] {
        var runs: [(end: Int, shift: Int)] = []
        for shift in 1..<max(1, height - header) {
            var y = header
            var marked = 0
            while y + shift < height && a.hashes[y + shift] == b.hashes[y] {
                if !b.uniform[y] { marked += 1 }
                y += 1
            }
            if marked >= minimumEvidenceRows { runs.append((y, shift)) }
        }
        return Array(
            runs.sorted { ($0.end, -$0.shift) > ($1.end, -$1.shift) }.prefix(pinnedCandidates))
    }

    /// `c` as a move over `columns`, when it convinces, if need be `rescored`, and no row
    /// contradicts it; failing that, scored again with something that stays in place over the
    /// page's bottom (a floating button, a composer, a footer's shadow) left out, since its rows
    /// lower the score or, spanning the width, contradict the move. `a` and `b` are the frames'
    /// signatures over `columns`, which `c` was scored from.
    static func believed(
        _ c: Candidate, _ previous: PixelBuffer, _ next: PixelBuffer, columns: Range<Int>,
        a: RowSignatures, b: RowSignatures
    ) -> FrameMatch? {
        if let moved = verified(c, previous, next, columns: columns, a: a, b: b) { return moved }
        guard !c.overlaid else { return nil }
        let overlaid = candidate(
            a, b, height: previous.height, header: c.header,
            overlayLimit: Int(Double(previous.height) * maximumOverlayShare))
        return verified(overlaid, previous, next, columns: columns, a: a, b: b)
    }

    static func verified(
        _ c: Candidate, _ previous: PixelBuffer, _ next: PixelBuffer, columns: Range<Int>,
        a: RowSignatures, b: RowSignatures
    ) -> FrameMatch? {
        let c = c.convincing ? c : rescored(c, previous, next, columns: columns, a: a, b: b)
        guard c.convincing, let best = c.best else { return nil }
        let content = previous.height - c.header - c.footer
        let found = contradictions(
            previous, next, columns: columns, previousStart: c.header + best.offset,
            nextStart: c.header, count: content - best.offset, previousUnique: c.uniqueA,
            nextUnique: c.uniqueB)
        guard found <= maximumContradictions else { return nil }
        return .moved(offset: best.offset, header: c.header, footer: c.footer, columns: columns)
    }

    /// The widest run of `span`'s columns that moved as one when the span as a whole didn't: a
    /// page between side panels that move by another amount or change in place. Strips with no
    /// offset of their own (blank, too little evidence) may sit inside a run but never end one.
    static func band(_ previous: PixelBuffer, _ next: PixelBuffer, span: Range<Int>, width: Int)
        -> FrameMatch?
    {
        let narrowest = Int((Double(width) * minimumBandShare).rounded(.up))
        guard span.count >= narrowest else { return nil }
        let stripWidth = max(minimumStripWidth, span.count / strips)
        let bounds = stride(from: span.lowerBound, to: span.upperBound, by: stripWidth).map {
            $0..<min($0 + stripWidth, span.upperBound)
        }
        let offsets: [Int?] = bounds.map { columns in
            let c = candidate(
                RowSignatures(previous, columns: columns), RowSignatures(next, columns: columns),
                height: previous.height)
            return c.convincing ? c.best?.offset : nil
        }
        var runs: [(columns: Range<Int>, offset: Int)] = []
        for offset in Set(offsets.compactMap { $0 }) {
            var first: Int?
            var last: Int?
            func close() {
                if let f = first, let l = last {
                    runs.append((bounds[f].lowerBound..<bounds[l].upperBound, offset))
                }
                first = nil
                last = nil
            }
            for (i, o) in offsets.enumerated() {
                if o == offset {
                    if first == nil { first = i }
                    last = i
                } else if o != nil {
                    close()
                }
            }
            close()
        }
        // Widest first; equal widths in column order, so the result never depends on set order.
        let ordered = runs.sorted {
            ($0.columns.count, -$0.columns.lowerBound) > ($1.columns.count, -$1.columns.lowerBound)
        }
        for run in ordered where run.columns.count >= narrowest {
            let a = RowSignatures(previous, columns: run.columns)
            let b = RowSignatures(next, columns: run.columns)
            let c = candidate(a, b, height: previous.height)
            guard let moved = believed(c, previous, next, columns: run.columns, a: a, b: b),
                case .moved(run.offset, let header, let footer, _) = moved
            else { continue }
            if panelsOnly(
                outside: run.columns, span: span, previous, next, offset: run.offset,
                rows: header..<(previous.height - footer - run.offset))
            {
                return moved
            }
        }
        return nil
    }

    /// Whether the changed columns on each side of `band` that didn't move with it by `offset`
    /// moved as one by an offset of their own: a side panel. Taken a side at a time, from the
    /// first such column to the last, since blank columns between a panel's letters move with
    /// any offset and would split it into slivers too thin to score. Anything else, an
    /// animation at the page's edge, would be filled flat in the stitch.
    static func panelsOnly(
        outside band: Range<Int>, span: Range<Int>, _ previous: PixelBuffer, _ next: PixelBuffer,
        offset: Int, rows: Range<Int>
    ) -> Bool {
        func stray(_ side: Range<Int>) -> Range<Int>? {
            let x = side.filter { !columnMoved($0, previous, next, offset: offset, rows: rows) }
            guard let first = x.first, let last = x.last else { return nil }
            return first..<(last + 1)
        }
        let groups = [
            stray(span.lowerBound..<max(span.lowerBound, band.lowerBound)),
            stray(min(span.upperBound, band.upperBound)..<span.upperBound),
        ].compactMap { $0 }
        return groups.allSatisfy { columns in
            candidate(
                RowSignatures(previous, columns: columns), RowSignatures(next, columns: columns),
                height: previous.height
            ).convincing
        }
    }

    /// `span` without a scroll bar's thumb at its right: a run of changed columns no wider than
    /// `widest` (the scroll-bar strip), set off from the rest by columns that didn't change. A
    /// scroll bar inside the region (a panel beside it) moves its thumb with every step, unlike
    /// the content beside it.
    static func withoutScrollThumb(
        _ span: Range<Int>, _ previous: PixelBuffer, _ next: PixelBuffer, widest: Int
    ) -> Range<Int> {
        func changed(_ x: Int) -> Bool {
            !columnMoved(x, previous, next, offset: 0, rows: 0..<previous.height)
        }
        var x = span.upperBound - 1
        while x >= span.lowerBound && span.upperBound - x <= widest + 1 && changed(x) { x -= 1 }
        guard span.upperBound - 1 - x <= widest else { return span }
        while x >= span.lowerBound && !changed(x) { x -= 1 }
        return x >= span.lowerBound ? span.lowerBound..<(x + 1) : span
    }

    /// Whether column `x` moved up by `offset` from `previous` to `next`: each of `next`'s
    /// `rows` is `previous`'s row `offset` lower. With `background`, compared as `flattened`
    /// toward it, pixel by pixel, without flattening either frame.
    static func columnMoved(
        _ x: Int, _ previous: PixelBuffer, _ next: PixelBuffer, offset: Int, rows: Range<Int>,
        flattenedToward background: UInt32? = nil
    ) -> Bool {
        previous.bytes.withUnsafeBytes { pa in
            next.bytes.withUnsafeBytes { pb in
                rows.allSatisfy { y in
                    let a = pa.loadUnaligned(
                        fromByteOffset: ((y + offset) * previous.width + x) * 4, as: UInt32.self)
                    let b = pb.loadUnaligned(
                        fromByteOffset: (y * next.width + x) * 4, as: UInt32.self)
                    guard a != b, let background else { return a == b }
                    return flat(a, toward: background) == flat(b, toward: background)
                }
            }
        }
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
    /// caret differs in a patch; text that differs across the width is other content. A row whose
    /// pixels all differ by at most one level per channel is the same content re-rasterised (a
    /// browser dithering a filtered image afresh at each scroll position).
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
                    let rowA = pa.baseAddress! + (p * previous.width + columns.lowerBound) * 4
                    let rowB = pb.baseAddress! + (n * next.width + columns.lowerBound) * 4
                    // A row the offset explains is identical: one compare clears it.
                    guard memcmp(rowA, rowB, columns.count * 4) != 0 else { continue }
                    func differs(_ x: Int) -> Bool {
                        rowA.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                            != rowB.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                    }
                    var first = 0
                    while !differs(first) { first += 1 }
                    var last = columns.count - 1
                    while !differs(last) { last -= 1 }
                    if (last - first + 1) * 4 > columns.count,
                        !nearlySame(rowA, rowB, bytes: columns.count * 4)
                    {
                        found += 1
                    }
                }
            }
        }
        return found
    }

    /// Whether every byte of two rows differs by at most one level: the same content
    /// re-rasterised, as a browser dithers an image or a filter afresh at each scroll position.
    static func nearlySame(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, bytes: Int) -> Bool {
        (0..<bytes).allSatisfy {
            abs(
                Int(a.load(fromByteOffset: $0, as: UInt8.self))
                    - Int(b.load(fromByteOffset: $0, as: UInt8.self))) <= 1
        }
    }

    /// `c` with its best offset scored again, counting an evidence pair whose signatures differ
    /// as matching when its rows are `nearlySame`. The other offsets keep their scores: dithering
    /// doesn't make a wrong offset's rows alike.
    static func rescored(
        _ c: Candidate, _ previous: PixelBuffer, _ next: PixelBuffer, columns: Range<Int>,
        a: RowSignatures, b: RowSignatures
    ) -> Candidate {
        guard let best = c.best else { return c }
        let start = c.header + best.offset
        let count = previous.height - c.header - c.footer - best.offset
        var matches = 0
        var evidence = 0
        previous.bytes.withUnsafeBytes { pa in
            next.bytes.withUnsafeBytes { pb in
                for i in 0..<count {
                    let p = start + i
                    let n = c.header + i
                    guard c.uniqueA[p], c.uniqueB[n] else { continue }
                    let same = a.hashes[p] == b.hashes[n]
                    if same && a.uniform[p] && b.uniform[n] { continue }
                    evidence += 1
                    if same
                        || nearlySame(
                            pa.baseAddress! + (p * previous.width + columns.lowerBound) * 4,
                            pb.baseAddress! + (n * next.width + columns.lowerBound) * 4,
                            bytes: columns.count * 4)
                    {
                        matches += 1
                    }
                }
            }
        }
        guard evidence >= minimumEvidenceRows else { return c }
        return Candidate(
            header: c.header, footer: c.footer,
            best: (best.offset, Double(matches) / Double(evidence)), runnerUp: c.runnerUp,
            uniqueA: c.uniqueA, uniqueB: c.uniqueB, overlaid: c.overlaid)
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
