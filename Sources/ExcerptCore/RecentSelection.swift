/// Which tiles of the Recent Captures panel are selected, and which one Return copies. Indices
/// are `RecentLayout.tiles()` positions: 0 the hero, 1–3 the upper row, 4–6 the lower row.
public struct RecentSelection: Equatable, Sendable {
    public enum Direction: Sendable { case left, right, up, down }

    public let count: Int
    public private(set) var selected: Set<Int>
    /// What Return copies; nil when there are no captures.
    public private(set) var focus: Int?
    /// The end a ⇧-click range grows from: the last tile clicked or toggled.
    private var anchor: Int?

    public init(count: Int) {
        self.count = count
        let first: Int? = count > 0 ? 0 : nil
        selected = first.map { [$0] } ?? []
        focus = first
        anchor = first
    }

    public mutating func click(_ index: Int) {
        guard valid(index) else { return }
        selected = [index]
        focus = index
        anchor = index
    }

    /// ⌘-click. The focus and anchor move to the tile even when it was just deselected.
    public mutating func toggle(_ index: Int) {
        guard valid(index) else { return }
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        focus = index
        anchor = index
    }

    /// ⇧-click: everything from the anchor to `index` inclusive; the anchor stays put.
    public mutating func extend(to index: Int) {
        guard valid(index) else { return }
        let from = anchor ?? index
        selected = Set(min(from, index)...max(from, index))
        focus = index
        anchor = from
    }

    /// An arrow key: focus goes to the neighbour on the grid and becomes the only selection.
    /// A move off the grid or onto an empty tile stays put.
    public mutating func move(_ direction: Direction) {
        guard let focus else { return }
        let target: Int
        switch direction {
        case .left: target = focus - 1
        case .right: target = focus + 1
        case .down: target = focus == 0 ? 1 : (focus <= 3 ? focus + 3 : focus)
        case .up: target = focus <= 3 ? 0 : focus - 3
        }
        click(valid(target) ? target : focus)
    }

    /// The selected indices in order, recordings left out: what Edit All opens.
    public func series(recordings: Set<Int>) -> [Int] {
        selected.subtracting(recordings).sorted()
    }

    private func valid(_ index: Int) -> Bool { index >= 0 && index < count }
}
