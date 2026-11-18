import ExcerptCore

extension ScrollFixtures {
    /// `frame` with its top `rows` rows blended a fifth of the way toward blue-grey at every
    /// pixel, ink too, as a translucent toolbar tints the page under it.
    public static func tinted(_ frame: PixelBuffer, rows: Int) -> PixelBuffer {
        paint(width: frame.width, height: frame.height) { x, y in
            let c = frame[x: x, y: y]
            guard y < rows else { return c }
            func blend(_ v: UInt8, _ toward: Double) -> UInt8 {
                UInt8((Double(v) * 0.8 + toward * 0.2).rounded())
            }
            return RGBA(r: blend(c.r, 120), g: blend(c.g, 130), b: blend(c.b, 160), a: c.a)
        }
    }

    /// A page of unique rows, or with a block that repeats, and the region a capture sees it
    /// through, combining the fixtures' features: sticky bars, a translucent toolbar band, a faint wallpaper fixed to the
    /// viewport, a hover block on the page row under the pointer, and a static side panel.
    public struct Scene: Sendable, CustomStringConvertible {
        public static let pageHeight = 1600
        public static let hoverHeight = 16
        public static let repeatPeriod = 250

        public var seed: UInt64
        /// Rows at the end of every `repeatPeriod` that are the same block each time, so a frame
        /// one period on aliases the true offset; 0 for none.
        public var block: Int
        public var width: Int
        public var viewport: Int
        public var header: Int
        public var footer: Int
        /// Rows a translucent toolbar tints at the top; 0 for none.
        public var tint: Int
        public var wallpaper: Bool
        /// The hover block's width; 0 for none.
        public var hover: Int
        /// Columns of a static side panel left of the page; 0 for none.
        public var panel: Int
        /// Captured as a window (its rounded top fixed) rather than an area.
        public var window: Bool

        public init(
            seed: UInt64, block: Int = 0, width: Int, viewport: Int, header: Int = 0,
            footer: Int = 0, tint: Int = 0, wallpaper: Bool = false, hover: Int = 0,
            panel: Int = 0, window: Bool = false
        ) {
            precondition(block < Self.repeatPeriod, "a repeated block fits in its period")
            self.seed = seed
            self.block = block
            self.width = width
            self.viewport = viewport
            self.header = header
            self.footer = footer
            self.tint = tint
            self.wallpaper = wallpaper
            self.hover = hover
            self.panel = panel
            self.window = window
        }

        /// The page's first `height` rows: every row is the same however long the page is drawn.
        public func page(height: Int = Self.pageHeight) -> PixelBuffer {
            let base = ScrollFixtures.page(width: width, height: height, seed: seed)
            guard block > 0 else { return base }
            let phase = Self.repeatPeriod - block
            return ScrollFixtures.paint(width: width, height: height) { x, y in
                let row = y % Self.repeatPeriod
                return row >= phase ? base[x: x, y: row] : base[x: x, y: y]
            }
        }

        public var chrome: ScrollChrome {
            window ? ScrollChrome(fixedTop: 2, fixedBottom: 0, fillsScrollBar: false) : .none
        }

        /// What the region shows with `page` scrolled to `offset` and the hover block, which
        /// follows the pointer from message to message, at row `hoverRow` of the region.
        public func frame(_ page: PixelBuffer, offset: Int, hoverRow: Int = 0) -> PixelBuffer {
            var view = ScrollFixtures.frame(
                page, offset: offset, viewport: viewport,
                header: header > 0
                    ? ScrollFixtures.bar(width: width, height: header, tone: 60) : nil,
                footer: footer > 0
                    ? ScrollFixtures.bar(width: width, height: footer, tone: 140) : nil)
            if hover > 0, hoverRow >= 0, hoverRow + Self.hoverHeight <= viewport {
                view = ScrollFixtures.animated(
                    view, x: 8, y: hoverRow, width: hover, height: Self.hoverHeight, phase: 7)
            }
            if tint > 0 { view = ScrollFixtures.tinted(view, rows: tint) }
            if wallpaper { view = ScrollFixtures.wallpapered(view) }
            if panel > 0 {
                view = ScrollFixtures.beside(
                    ScrollFixtures.page(width: panel, height: viewport, seed: seed &+ 1), view)
            }
            return view
        }

        public var description: String {
            "Scene(seed: \(seed), block: \(block), width: \(width), viewport: \(viewport), header: \(header), "
                + "footer: \(footer), tint: \(tint), wallpaper: \(wallpaper), hover: \(hover), "
                + "panel: \(panel), window: \(window))"
        }
    }
}
