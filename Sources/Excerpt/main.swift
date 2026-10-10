import AppKit
import ExcerptExport

// `excerpt read <image>` and `excerpt help` run headless, before any NSApplication exists.
let arguments = CommandLine.arguments
if let status = ReadCommand.main(Array(arguments.dropFirst()), invokedAt: arguments.first ?? "") {
    exit(status)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
