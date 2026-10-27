import CoreGraphics

/// One on-screen window as the window list stacks it.
public struct StackedWindow: Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let layer: Int
    /// Quartz global points.
    public let frame: CGRect
}

public enum WindowStack {
    /// The windows that show over `window` as part of it: its app's windows on higher layers in
    /// front of it — menus, submenus, popovers, tooltips — that overlap it or one another,
    /// front to back as `stack` (all on-screen windows, front to back) lists them.
    public static func overlays(of window: StackedWindow, in stack: [StackedWindow])
        -> [StackedWindow]
    {
        guard let index = stack.firstIndex(of: window) else { return [] }
        var candidates = stack[..<index].filter { $0.pid == window.pid && $0.layer > window.layer }
        var reach = window.frame
        var taken: [StackedWindow] = []
        while let next = candidates.firstIndex(where: { $0.frame.intersects(reach) }) {
            let overlay = candidates.remove(at: next)
            taken.append(overlay)
            reach = reach.union(overlay.frame)
        }
        return stack.filter(taken.contains)
    }

    /// The area `window` and its `overlays` cover together, in Quartz global points.
    public static func frame(of window: StackedWindow, with overlays: [StackedWindow]) -> CGRect {
        overlays.reduce(window.frame) { $0.union($1.frame) }
    }
}
