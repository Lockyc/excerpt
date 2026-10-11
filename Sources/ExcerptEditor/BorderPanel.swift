import AppKit
import ExcerptCore

extension Border.Width {
    /// The width control's segment label.
    var label: String { "\(Int(points))pt" }
}

/// The Border button's drop-down: on/off, colour and width. Every choice goes straight to the
/// model; `show` brings the controls in line with it.
@MainActor
final class BorderPanel: NSViewController {
    private let model: EditorModel
    private let toggle = NSSwitch()
    private let colors = NSSegmentedControl()
    private let widths = NSSegmentedControl()

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        toggle.target = self
        toggle.action = #selector(toggled)
        let title = NSTextField(labelWithString: "Border")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let header = NSStackView(views: [title, NSView(), toggle])
        header.orientation = .horizontal

        colors.segmentCount = Palette.allCases.count
        colors.trackingMode = .selectOne
        for (i, color) in Palette.allCases.enumerated() {
            colors.setImage(EditorWindowController.swatch(color), forSegment: i)
            colors.setWidth(36, forSegment: i)
            colors.setToolTip(color.rawValue.capitalized, forSegment: i)
        }
        colors.target = self
        colors.action = #selector(colorChosen)

        widths.segmentCount = Border.Width.allCases.count
        widths.trackingMode = .selectOne
        for (i, width) in Border.Width.allCases.enumerated() {
            widths.setLabel(width.label, forSegment: i)
            widths.setWidth(60, forSegment: i)
        }
        widths.target = self
        widths.action = #selector(widthChosen)

        for control in [toggle, colors, widths] as [NSControl] {
            control.controlSize = .large
            control.refusesFirstResponder = true
        }

        let stack = NSStackView(views: [header, colors, widths])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        let inset: CGFloat = 20
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: colors.widthAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
        ])
        view = container
        refresh()
    }

    /// Brings the controls in line with the model.
    func refresh() {
        guard isViewLoaded else { return }
        let style = model.borderStyle
        toggle.state = model.document.border == nil ? .off : .on
        colors.selectedSegment = Palette.allCases.firstIndex(of: style.color) ?? 0
        widths.selectedSegment = Border.Width.allCases.firstIndex(of: style.width) ?? 0
    }

    @objc private func toggled() { model.setBorder(toggle.state == .on) }

    @objc private func colorChosen() {
        model.setBorderColor(Palette.allCases[colors.selectedSegment])
    }

    @objc private func widthChosen() {
        model.setBorderWidth(Border.Width.allCases[widths.selectedSegment])
    }
}
