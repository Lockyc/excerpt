import CoreGraphics

/// The Input Monitoring permission, which the recording's shortcut log needs to hear key
/// presses in other apps.
public enum InputMonitoring {
    public static func hasPermission() -> Bool { CGPreflightListenEventAccess() }

    /// Asks the system to prompt for the permission; true when it is already granted.
    @discardableResult
    public static func request() -> Bool { CGRequestListenEventAccess() }
}
