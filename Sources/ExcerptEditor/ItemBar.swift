import AppKit
import ExcerptCore

extension Palette {
    /// A round swatch for colour controls.
    var swatch: NSImage { RGBA.swatch(rgba) }
}

extension RGBA {
    /// A round swatch of `color`, or an empty ring for nil.
    static func swatch(_ color: RGBA?) -> NSImage {
        NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color {
                NSColor(cgColor: color.cgColor)?.setFill()
                circle.fill()
            }
            NSColor.separatorColor.setStroke()
            circle.stroke()
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

extension TextStyle {
    /// A text size as the bar shows it: "17.5 pt", "30 pt".
    static func label(points: Double) -> String {
        "\(points.formatted(.number.precision(.fractionLength(0...1)))) pt"
    }
}

extension TextFont {
    var label: String {
        switch self {
        case .sans: "Sans"
        case .mono: "Mono"
        case .serif: "Serif"
        }
    }
}

extension TextAlign {
    /// The alignment control's segments, in order.
    static let shown: [TextAlign] = [.left, .centered]

    var label: String {
        switch self {
        case .left: "Align left"
        case .centered: "Centre"
        }
    }

    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .centered: "text.aligncenter"
        }
    }
}

/// The selected item's own controls, floating beside it, built from `EditorModel.itemOptions`.
/// Every control refuses first responder, so clicking one leaves typed text in its field.
@MainActor
final class ItemBar: NSVisualEffectView {
    var onColor: (AnnotationColor) -> Void = { _ in }
    var onEyedropper: () -> Void = {}
    var onSize: (StrokeWidth) -> Void = { _ in }
    var onTextSize: (Double) -> Void = { _ in }
    var onBold: (Bool) -> Void = { _ in }
    var onFont: (TextFont) -> Void = { _ in }
    var onAlignment: (TextAlign) -> Void = { _ in }
    var onBackground: (Bool) -> Void = { _ in }
    var onClosed: (Bool) -> Void = { _ in }
    var onFill: (Bool) -> Void = { _ in }
    var onMove: (_ earlier: Bool) -> Void = { _ in }
    var onSpanStart: () -> Void = {}
    var onSpanEnd: () -> Void = {}
    var onWholeClip: () -> Void = {}
    var onDelete: () -> Void = {}

    private let stack = NSStackView()
    /// Each control shown: its option, its view in `stack`, and the target-action objects its
    /// closures live in (a control's target is weak).
    private var slots: [(option: ItemOption, view: NSView, actions: [Action])] = []
    /// Collects what `wire` makes while one control is built.
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

    /// Shows `options` and sizes the bar to fit them. A control whose option only changed value
    /// is updated in place, so one being clicked or held (the size stepper's autorepeat) carries
    /// on through the change its action makes; the rest are rebuilt.
    func show(_ options: [ItemOption]) {
        guard options != slots.map(\.option) else { return }
        if options.count != slots.count {
            for slot in slots { slot.view.removeFromSuperview() }
            slots = options.map(build)
            for slot in slots { stack.addArrangedSubview(slot.view) }
        } else {
            for (i, option) in options.enumerated() where option != slots[i].option {
                if update(slots[i].view, from: slots[i].option, to: option) {
                    slots[i].option = option
                } else {
                    slots[i].view.removeFromSuperview()
                    slots[i] = build(option)
                    stack.insertArrangedSubview(slots[i].view, at: i)
                }
            }
        }
        setFrameSize(stack.fittingSize)
    }

    private func build(_ option: ItemOption) -> (
        option: ItemOption, view: NSView, actions: [Action]
    ) {
        actions = []
        let view = control(for: option)
        _ = update(view, from: option, to: option)
        defer { actions = [] }
        return (option, view, actions)
    }

    /// Sets the value `to` carries on `view`, built for `from`; false when it can't, being a
    /// control of another kind or one rebuilt for any change.
    private func update(_ view: NSView, from: ItemOption, to: ItemOption) -> Bool {
        switch (from, to) {
        case (.size, .size(let selected)):
            guard let control = view as? NSSegmentedControl else { return false }
            control.selectedSegment =
                selected.flatMap { StrokeWidth.allCases.firstIndex(of: $0) } ?? -1
        case (.textSize, .textSize(let points)):
            guard let row = view as? NSStackView,
                let label = row.arrangedSubviews.first as? NSTextField,
                let stepper = row.arrangedSubviews.last as? NSStepper
            else { return false }
            label.stringValue = TextStyle.label(points: points)
            stepper.doubleValue = points
        case (.bold, .bold(let on)), (.background, .background(let on)):
            guard let button = view as? NSButton else { return false }
            button.state = on ? .on : .off
        case (.font, .font(let selected)):
            guard let menu = view as? NSPopUpButton else { return false }
            menu.selectItem(at: TextFont.allCases.firstIndex(of: selected) ?? 0)
        case (.alignment, .alignment(let selected)):
            guard let control = view as? NSSegmentedControl else { return false }
            control.selectedSegment = TextAlign.shown.firstIndex(of: selected) ?? -1
        default:
            return false
        }
        return true
    }

    private func control(for option: ItemOption) -> NSView {
        switch option {
        case .color(let selected, let lastSampled, let picking):
            let palette = Palette.allCases
            let control = segments(palette, selected: .initial) { control, i, color in
                control.setImage(color.swatch, forSegment: i)
                control.setToolTip(color.rawValue.capitalized, forSegment: i)
            }
            // The last eyedropper sample is the segment after the palette.
            let sample = palette.count
            control.segmentCount = sample + 1
            control.setWidth(28, forSegment: sample)
            control.setImage(RGBA.swatch(lastSampled), forSegment: sample)
            control.setEnabled(lastSampled != nil, forSegment: sample)
            control.setToolTip(
                lastSampled == nil
                    ? "Pick a colour with the eyedropper first" : "Last picked colour",
                forSegment: sample)
            switch selected {
            case .palette(let chosen):
                control.selectedSegment = palette.firstIndex(of: chosen) ?? 0
            case .sampled(let color):
                control.selectedSegment = color == lastSampled ? sample : -1
            }
            let picker = wire(control) { [weak self] in
                let i = ($0 as! NSSegmentedControl).selectedSegment
                if i < sample {
                    self?.onColor(.palette(palette[i]))
                } else if let lastSampled {
                    self?.onColor(.sampled(lastSampled))
                }
            }
            let dropper = symbolButton("eyedropper", label: "Eyedropper")
            dropper.setButtonType(.pushOnPushOff)
            dropper.state = picking ? .on : .off
            dropper.toolTip = "Pick a colour from the capture (Esc cancels)"
            let eyedropper = wire(dropper) { [weak self] _ in self?.onEyedropper() }
            let row = NSStackView(views: [picker, eyedropper])
            row.orientation = .horizontal
            row.spacing = 4
            return row
        // These kinds' values are set by `update`.
        case .size:
            let control = segments(StrokeWidth.allCases, selected: nil) { control, i, width in
                control.setLabel(width.label, forSegment: i)
                control.setToolTip(width.tip, forSegment: i)
            }
            return wire(control) { [weak self] in
                self?.onSize(StrokeWidth.allCases[($0 as! NSSegmentedControl).selectedSegment])
            }
        case .textSize:
            let range = TextStyle.pointsRange
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.toolTip = "Text size"
            let stepper = NSStepper()
            stepper.minValue = range.lowerBound
            stepper.maxValue = range.upperBound
            stepper.increment = EditorModel.textSizeStep
            stepper.valueWraps = false
            stepper.autorepeat = true
            stepper.toolTip =
                "Text size, \(TextStyle.label(points: range.lowerBound)) to "
                + TextStyle.label(points: range.upperBound)
            let step = wire(stepper) { [weak self] in self?.onTextSize($0.doubleValue) }
            let row = NSStackView(views: [label, step])
            row.orientation = .horizontal
            row.spacing = 2
            return row
        case .bold:
            let button = symbolButton("bold", label: "Bold")
            button.setButtonType(.pushOnPushOff)
            button.toolTip = "Bold"
            return wire(button) { [weak self] in self?.onBold(($0 as! NSButton).state == .on) }
        case .font:
            let menu = NSPopUpButton(frame: .zero, pullsDown: false)
            for font in TextFont.allCases { menu.addItem(withTitle: font.label) }
            menu.toolTip = "Font"
            return wire(menu) { [weak self] in
                let i = ($0 as! NSPopUpButton).indexOfSelectedItem
                if TextFont.allCases.indices.contains(i) { self?.onFont(TextFont.allCases[i]) }
            }
        case .alignment:
            let alignments = TextAlign.shown
            let control = segments(alignments, selected: nil) { control, i, alignment in
                control.setImage(
                    NSImage(
                        systemSymbolName: alignment.symbol,
                        accessibilityDescription: alignment.label),
                    forSegment: i)
                control.setToolTip(alignment.label, forSegment: i)
            }
            return wire(control) { [weak self] in
                self?.onAlignment(alignments[($0 as! NSSegmentedControl).selectedSegment])
            }
        case .background:
            let button = symbolButton("character.textbox", label: "Background")
            button.setButtonType(.pushOnPushOff)
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
        case .spanStart(let reason):
            let button = symbolButton("arrow.right.to.line", label: "Start here")
            button.isEnabled = reason == nil
            button.toolTip = reason ?? "Start the blur at the playhead"
            return wire(button) { [weak self] _ in self?.onSpanStart() }
        case .spanEnd(let reason):
            let button = symbolButton("arrow.left.to.line", label: "End here")
            button.isEnabled = reason == nil
            button.toolTip = reason ?? "End the blur at the playhead"
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

    /// One segment per value, `selected` lit; none when it is nil.
    private func segments<Value: Equatable>(
        _ values: [Value], selected: Value?,
        configure: (NSSegmentedControl, Int, Value) -> Void
    ) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = values.count
        control.trackingMode = .selectOne
        for (i, value) in values.enumerated() {
            configure(control, i, value)
            control.setWidth(28, forSegment: i)
        }
        control.selectedSegment = selected.flatMap { values.firstIndex(of: $0) } ?? -1
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
