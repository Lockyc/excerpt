import ExcerptTestSupport
import PropertyBased

/// Generated `ScrollFixtures.Scene`s: every feature shrinks to absent, so a counterexample
/// shrinks to the fewest features that still fail.
enum ScrollSceneGen {
    /// Any scene the fixtures can draw: bars, a toolbar band, wallpaper, a hover block and a side
    /// panel, each optional, in an area or a window, over a page that may repeat a block. Only a
    /// window has a toolbar band: an area has no title bar to hold one, and halts on a changing
    /// header by design. No toolbar band shows a repeated block: that alias is the open known
    /// issue in `StitchMatcherTests.knownIssueRepeatedContentUnderAWindowsToolbarCanAlias`.
    static var scene: Generator<ScrollFixtures.Scene, some SendableSequenceType> {
        zip(
            zip(Gen.uint64(in: 1...100_000), Gen.int(in: 0...200)), Gen.int(in: 64...160),
            Gen.int(in: 120...300), Gen.int(in: 0...40), Gen.int(in: 0...30),
            Gen.int(in: 0...25), Gen.bool, Gen.int(in: 0...80), Gen.int(in: 0...40), Gen.bool
        ).map { page, width, viewport, header, footer, tintShare, wallpaper, hover, panel, window in
            let tint = window ? viewport * tintShare / 100 : 0
            return ScrollFixtures.Scene(
                seed: page.0, block: page.1 < 40 || tint > 0 ? 0 : page.1, width: width,
                viewport: viewport, header: header < 8 ? 0 : header,
                footer: footer < 8 ? 0 : footer, tint: tint, wallpaper: wallpaper,
                hover: hover < 8 ? 0 : min(hover, width - 16), panel: panel < 16 ? 0 : panel,
                window: window)
        }
    }

    /// A plain page of unique rows: no bars, band, wallpaper, hover or panel.
    static var plain: Generator<ScrollFixtures.Scene, some SendableSequenceType> {
        zip(Gen.uint64(in: 1...100_000), Gen.int(in: 64...160), Gen.int(in: 120...300)).map {
            seed, width, viewport in
            ScrollFixtures.Scene(seed: seed, width: width, viewport: viewport)
        }
    }
}
