import CoreGraphics

public enum SelectionMath {
    /// Smallest side, in points, that counts as a deliberate selection. Anything smaller is a
    /// click or a slip and cancels the capture.
    public static let minimumSide: CGFloat = 4

    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The drag clamped to the display it started on: what is actually captured, so the size
    /// check judges the same rectangle the crop uses.
    public static func rect(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CGRect {
        rect(from: a, to: b).intersection(bounds)
    }

    public static func isCapturable(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}

/// The edges of a settled selection a press grabs to resize it; empty grabs its inside, which
/// moves it.
public struct SelectionGrip: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = SelectionGrip(rawValue: 1)
    public static let right = SelectionGrip(rawValue: 2)
    public static let top = SelectionGrip(rawValue: 4)
    public static let bottom = SelectionGrip(rawValue: 8)
}

extension SelectionMath {
    /// How far, in points, a press may land from an edge and still grab it.
    public static let gripReach: CGFloat = 6

    /// What a press at `point` grabs of `rect`: the edges within reach (the nearer of two
    /// opposite ones), none from further inside, nil outside it.
    public static func grip(at point: CGPoint, on rect: CGRect) -> SelectionGrip? {
        guard rect.insetBy(dx: -gripReach, dy: -gripReach).contains(point) else { return nil }
        func nearer(
            _ value: CGFloat, _ low: CGFloat, _ high: CGFloat, _ lowGrip: SelectionGrip,
            _ highGrip: SelectionGrip
        ) -> SelectionGrip {
            let toLow = abs(value - low)
            let toHigh = abs(value - high)
            guard min(toLow, toHigh) <= gripReach else { return [] }
            return toLow <= toHigh ? lowGrip : highGrip
        }
        return nearer(point.x, rect.minX, rect.maxX, .left, .right)
            .union(nearer(point.y, rect.minY, rect.maxY, .top, .bottom))
    }

    /// `rect` after a drag of `delta` from `grip`: the gripped edges follow it, past the
    /// opposite edge if dragged there; with no edges gripped the whole rect moves, kept on the
    /// display at its size.
    public static func adjust(
        _ rect: CGRect, grip: SelectionGrip, by delta: CGSize, within bounds: CGRect
    ) -> CGRect {
        guard !grip.isEmpty else {
            return CGRect(
                x: clamp(rect.minX + delta.width, bounds.minX, bounds.maxX - rect.width),
                y: clamp(rect.minY + delta.height, bounds.minY, bounds.maxY - rect.height),
                width: rect.width, height: rect.height)
        }
        let a = CGPoint(
            x: rect.minX + (grip.contains(.left) ? delta.width : 0),
            y: rect.minY + (grip.contains(.top) ? delta.height : 0))
        let b = CGPoint(
            x: rect.maxX + (grip.contains(.right) ? delta.width : 0),
            y: rect.maxY + (grip.contains(.bottom) ? delta.height : 0))
        return self.rect(from: a, to: b, within: bounds)
    }

    /// Clear space between the mode bar and the selection or pointer it is placed by.
    public static let barGap: CGFloat = 12

    /// Where the mode bar sits, in the overlay's top-left points: centred in a selection with
    /// room around it, else below it, above it, or inside its bottom edge; with no selection,
    /// just below the pointer, else above it. Always on the display.
    public static func barFrame(
        for selection: CGRect?, cursor: CGPoint, size: CGSize, in bounds: CGRect
    ) -> CGRect {
        let gap = barGap
        let around = selection ?? CGRect(origin: cursor, size: .zero).insetBy(dx: 0, dy: -gap)
        let x = clamp(around.midX - size.width / 2, bounds.minX, bounds.maxX - size.width)
        let y: CGFloat
        if let selection, selection.width >= size.width + 2 * gap,
            selection.height >= size.height + 2 * gap
        {
            y = selection.midY - size.height / 2
        } else if around.maxY + gap + size.height <= bounds.maxY {
            y = around.maxY + gap
        } else if around.minY - gap - size.height >= bounds.minY {
            y = around.minY - gap - size.height
        } else {
            y = clamp(around.maxY - gap - size.height, bounds.minY, bounds.maxY - size.height)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

extension SelectionMath {
    /// Where the start button sits for `selection`, in the overlay's top-left points:
    /// `ScrollChromeLayout.startButton` on the selection flipped into AppKit's bottom-left space.
    public static func startButtonFrame(for selection: CGRect, size: CGSize, in bounds: CGRect)
        -> CGRect
    {
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX, y: bounds.minY + bounds.maxY - rect.maxY, width: rect.width,
                height: rect.height)
        }
        return flip(
            ScrollChromeLayout.startButton(size: size, region: flip(selection), visible: bounds))
    }
}
