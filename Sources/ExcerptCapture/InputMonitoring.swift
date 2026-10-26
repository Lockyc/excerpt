import CoreGraphics
import IOKit.hid

/// The Input Monitoring permission, which the recording's shortcut log needs to hear key
/// presses in other apps.
public enum InputMonitoring {
    public static func hasPermission() -> Bool { CGPreflightListenEventAccess() }

    /// Whether the user has yet to grant or deny the permission, so `request` would prompt.
    public static func isUndecided() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown
    }

    /// Asks the system to prompt for the permission; true when it is already granted.
    @discardableResult
    public static func request() -> Bool { CGRequestListenEventAccess() }
}
