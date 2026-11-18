import ExcerptCore
import Foundation

/// Replays a full-page image as an auto-scrolling capture: for each region height and pointer
/// row, the frames a viewport that tall sees, one auto-scroll step apart, through a
/// `ScrollSession`. A pointer row puts a hover block (`ScrollFixtures.animated`, `hoverHeight`
/// rows across `hoverWidthShare` of the width) on the region's row under the pointer, as a chat
/// shows a toolbar on whichever message is under it.
public enum ScrollReplay {
    public static let hoverHeight = 24
    public static let hoverWidthShare = 0.3

    public struct Combination: Equatable, Sendable, CustomStringConvertible {
        public let regionHeight: Int
        /// The region row under the pointer; nil for no hover block.
        public let pointer: Int?
        public var description: String {
            "region \(regionHeight) rows, pointer \(pointer.map(String.init) ?? "none")"
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The stitch is exactly the page.
        case reachedEnd
        /// The session stopped short and said so: the user saves or discards what's stitched.
        case halted(ScrollPhase)
        /// The session finished with a stitch that is not the page: a fabricated seam.
        case wrong(height: Int)
    }

    public struct Result: Sendable {
        public let combination: Combination
        public let outcome: Outcome
    }

    /// Every combination's outcome over `page`. A pointer is a share of the region's height
    /// down from its top; nil for none.
    public static func run(page: PixelBuffer, regionHeights: [Int], pointers: [Double?])
        -> [Result]
    {
        regionHeights.filter { $0 > 0 && $0 <= page.height }.flatMap { height in
            pointers.map { share in
                let pointer = share.map { Int(Double(height) * $0) }
                let combination = Combination(regionHeight: height, pointer: pointer)
                return Result(
                    combination: combination, outcome: replay(page, combination))
            }
        }
    }

    static func replay(_ page: PixelBuffer, _ c: Combination) -> Outcome {
        func frame(_ offset: Int) -> PixelBuffer {
            let view = ScrollFixtures.frame(page, offset: offset, viewport: c.regionHeight)
            guard let pointer = c.pointer, pointer >= 0,
                pointer + hoverHeight <= c.regionHeight
            else { return view }
            return ScrollFixtures.animated(
                view, x: page.width / 8, y: pointer,
                width: Int(Double(page.width) * hoverWidthShare), height: hoverHeight,
                phase: 7)
        }
        let travel = max(1, Int((Double(c.regionHeight) * ScrollSession.stepShare).rounded()))
        let end = page.height - c.regionHeight
        var session = ScrollSession(first: frame(0), scale: 1, canAutoScroll: true)
        var offset = 0
        for _ in 0..<(end / travel + ScrollSession.stillStepsToStop + 2)
        where session.phase == .auto {
            offset = min(offset + travel, end)
            session.stepped(frame(offset), travel: travel)
        }
        guard session.phase == .finished else { return .halted(session.phase) }
        let image = session.stitcher.image
        // With a hover block the stitch keeps each frame's own pixels, so only its size and the
        // rows clear of the block can be held to the page.
        if c.pointer == nil {
            return image == page ? .reachedEnd : .wrong(height: image.height)
        }
        return image.height == page.height ? .reachedEnd : .wrong(height: image.height)
    }

    /// The PNGs in the folder `EXCERPT_REPLAY_DIR` names, as pages; empty when it is unset.
    public static func localPages() throws -> [(name: String, page: PixelBuffer)] {
        guard let dir = ProcessInfo.processInfo.environment["EXCERPT_REPLAY_DIR"], !dir.isEmpty
        else { return [] }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map {
            ($0.lastPathComponent, PixelBuffer(try PNGCodec.decode(Data(contentsOf: $0)).image))
        }
    }
}
