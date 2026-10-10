import AppKit

/// A button that acts on the first click even while another app is frontmost.
@MainActor
public final class FirstMouseButton: NSButton {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
