import AppKit
import ExcerptCore

extension Palette {
    /// A round swatch for colour controls.
    var swatch: NSImage {
        NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            NSColor(cgColor: self.rgba.cgColor)?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}

extension StrokeWidth {
    /// The size control's segment label.
    var label: String {
        switch self {
        case .thin: "S"
        case .medium: "M"
        case .thick: "L"
        }
    }

    var tip: String {
        "\(Int(points))pt stroke · \(Int(textPoints))pt text · \(Int(stepPoints))pt step"
    }
}

/// The selected item's own controls, floating beside it, built from `EditorModel.itemOptions`.
/// Every control refuses first responder, so clicking one leaves typed text in its field.
@MainActor
final class ItemBar: NSVisualEffectView {
    var onColor: (Palette) -> Void = { _ in }
    var onSize: (StrokeWidth) -> Void = { _ in }
    var onBackground: (Bool) -> Void = { _ in }
    var onClosed: (Bool) -> Void = { _ in }
    var onFill: (Bool) -> Void = { _ in }
    var onMove: (_ earlier: Bool) -> Void = { _ in }
    var onSpanStart: () -> Void = {}
    var onSpanEnd: () -> Void = {}
    var onWholeClip: () -> Void = {}
    var onDelete: () -> Void = {}

    private let stack = NSStackView()
    private var shown: [ItemOption] = []
    /// Target-action needs objects; each control's closure lives here.
    private var actions: [Action] = []

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A disabled control passes its click up the responder chain; the bar ends it here, so the
    /// click never reaches the canvas underneath.
    override func mouseDown(with event: NSEvent) {}

    /// Rebuilds the controls when the options change, and sizes the bar to fit them.
    func show(_ options: [ItemOption]) {
        guard options != shown else { return }
        shown = options
        actions = []
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for option in options { stack.addArrangedSubview(control(for: option)) }
        setFrameSize(stack.fittingSize)
    }

    private func control(for option: ItemOption) -> NSView {
        switch option {
        case .color(let selected):
            let control = segments(Palette.allCases, selected: selected) { control, i, color in
                control.setImage(color.swatch, forSegment: i)
                control.setToolTip(color.rawValue.capitalized, forSegment: i)
            }
            return wire(control) { [weak self] in
                self?.onColor(Palette.allCases[($0 as! NSSegmentedControl).selectedSegment])
            }
        case .size(let selected):
            let control = segments(StrokeWidth.allCases, selected: selected) { control, i, width in
                control.setLabel(width.label, forSegment: i)
                control.setToolTip(width.tip, forSegment: i)
            }
            return wire(control) { [weak self] in
                self?.onSize(StrokeWidth.allCases[($0 as! NSSegmentedControl).selectedSegment])
            }
        case .background(let on):
            let button = symbolButton("character.textbox", label: "Background")
            button.setButtonType(.pushOnPushOff)
            button.state = on ? .on : .off
            button.toolTip = "Text on a background of its colour"
            return wire(button) { [weak self] in
                self?.onBackground(($0 as! NSButton).state == .on)
            }
        case .closed(let on, let enabled):
            let button = symbolButton("pentagon", label: "Closed")
            button.setButtonType(.pushOnPushOff)
            button.state = on ? .on : .off
            button.isEnabled = enabled
            button.toolTip =
                enabled ? "Join the last point to the first" : "A path needs three points to close"
            return wire(button) { [weak self] in self?.onClosed(($0 as! NSButton).state == .on) }
        case .fill(let on, let enabled):
            let button = symbolButton("pentagon.fill", label: "Fill")
            button.setButtonType(.pushOnPushOff)
            button.state = on ? .on : .off
            button.isEnabled = enabled
            button.toolTip = enabled ? "Tint the inside in its colour" : "Close the path to fill it"
            return wire(button) { [weak self] in self?.onFill(($0 as! NSButton).state == .on) }
        case .moveEarlier(let enabled):
            let button = symbolButton("chevron.left", label: "Move earlier")
            button.isEnabled = enabled
            button.toolTip = enabled ? "Move earlier: one number lower" : "Already step 1"
            return wire(button) { [weak self] _ in self?.onMove(true) }
        case .moveLater(let enabled):
            let button = symbolButton("chevron.right", label: "Move later")
            button.isEnabled = enabled
            button.toolTip = enabled ? "Move later: one number higher" : "Already the last step"
            return wire(button) { [weak self] _ in self?.onMove(false) }
        case .spanStart:
            let button = symbolButton("arrow.right.to.line", label: "Start here")
            button.toolTip = "Start the blur at the playhead"
            return wire(button) { [weak self] _ in self?.onSpanStart() }
        case .spanEnd:
            let button = symbolButton("arrow.left.to.line", label: "End here")
            button.toolTip = "End the blur at the playhead"
            return wire(button) { [weak self] _ in self?.onSpanEnd() }
        case .wholeClip(let enabled):
            let button = symbolButton("arrow.left.and.right", label: "Whole clip")
            button.isEnabled = enabled
            button.toolTip = enabled ? "Blur over the whole clip" : "Already over the whole clip"
            return wire(button) { [weak self] _ in self?.onWholeClip() }
        case .delete:
            let button = symbolButton("trash", label: "Delete")
            button.contentTintColor = .systemRed
            button.toolTip = "Delete (⌫)"
            return wire(button) { [weak self] _ in self?.onDelete() }
        }
    }

    private func segments<Value: Equatable>(
        _ values: [Value], selected: Value,
        configure: (NSSegmentedControl, Int, Value) -> Void
    ) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = values.count
        control.trackingMode = .selectOne
        for (i, value) in values.enumerated() {
            configure(control, i, value)
            control.setWidth(28, forSegment: i)
        }
        control.selectedSegment = values.firstIndex(of: selected) ?? 0
        return control
    }

    private func symbolButton(_ symbol: String, label: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        return button
    }

    private func wire(_ control: NSControl, _ run: @escaping (NSControl) -> Void) -> NSControl {
        let action = Action(run)
        actions.append(action)
        control.target = action
        control.action = #selector(Action.fire(_:))
        control.refusesFirstResponder = true
        return control
    }

    private final class Action: NSObject {
        let run: (NSControl) -> Void
        init(_ run: @escaping (NSControl) -> Void) { self.run = run }
        @objc func fire(_ sender: NSControl) { run(sender) }
    }
}
