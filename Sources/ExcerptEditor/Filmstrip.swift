import AppKit

/// A series' captures in a row along the bottom of the editor: each cell shows the capture's
/// render, its step range and its Restart at 1 switch; clicking a cell shows that capture.
@MainActor
final class Filmstrip: NSView {
    static let height: CGFloat = 132
    private static let imageHeight: CGFloat = 72
    private static let cellWidth: CGFloat = 132

    var onSelect: (Int) -> Void = { _ in }
    var onRestart: (Int, Bool) -> Void = { _, _ in }
    private var cells: [Cell] = []

    /// The cell drawn as the one in view.
    var current = 0 {
        didSet { for (i, cell) in cells.enumerated() { cell.isCurrent = i == current } }
    }

    init(count: Int) {
        super.init(frame: .zero)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for i in 0..<count {
            let cell = Cell(index: i, strip: self)
            cells.append(cell)
            row.addArrangedSubview(cell)
        }
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = row
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
        current = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The step range as the cell shows it.
    static func label(first: Int, count: Int) -> String {
        switch count {
        case 0: "No steps"
        case 1: "Step \(first)"
        default: "Steps \(first)–\(first + count - 1)"
        }
    }

    func setImage(_ image: CGImage, at index: Int) {
        cells[index].image.image = NSImage(cgImage: image, size: .zero)
    }

    /// The first capture always starts at 1, and one without steps has nothing to restart, so
    /// the switch is disabled for both and says why.
    func setSteps(first: Int, count: Int, restarts: Bool, at index: Int) {
        let cell = cells[index]
        cell.label.stringValue = Self.label(first: first, count: count)
        cell.restart.state = restarts ? .on : .off
        cell.restart.isEnabled = index > 0 && count > 0
        cell.restart.toolTip =
            index == 0
            ? "The first capture starts at 1"
            : count == 0 ? "No steps to number" : "Number this capture's steps from 1"
    }

    func restartSwitch(at index: Int) -> NSButton { cells[index].restart }

    fileprivate func selected(_ index: Int) { onSelect(index) }
    fileprivate func restarted(_ index: Int, _ on: Bool) { onRestart(index, on) }

    private final class Cell: NSStackView {
        let index: Int
        weak var strip: Filmstrip?
        let image = NSButton()
        let label = NSTextField(labelWithString: "")
        let restart = NSButton(checkboxWithTitle: "Restart at 1", target: nil, action: nil)

        var isCurrent = false {
            didSet {
                layer?.borderWidth = isCurrent ? 2 : 0
                layer?.backgroundColor =
                    isCurrent
                    ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15)
                        .cgColor : nil
            }
        }

        init(index: Int, strip: Filmstrip) {
            self.index = index
            self.strip = strip
            super.init(frame: .zero)
            orientation = .vertical
            spacing = 2
            edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            image.isBordered = false
            image.imageScaling = .scaleProportionallyDown
            image.title = ""
            image.target = self
            image.action = #selector(choose)
            image.setAccessibilityLabel("Capture \(index + 1)")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            restart.controlSize = .small
            restart.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            restart.target = self
            restart.action = #selector(toggle)
            for view in [image, label, restart] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addArrangedSubview(view)
            }
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Filmstrip.cellWidth),
                image.heightAnchor.constraint(equalToConstant: Filmstrip.imageHeight),
                image.widthAnchor.constraint(equalToConstant: Filmstrip.cellWidth - 8),
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func choose() { strip?.selected(index) }
        @objc private func toggle() { strip?.restarted(index, restart.state == .on) }
    }
}
