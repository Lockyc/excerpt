import AppKit
import ExcerptExport

// A read of one image in a fresh process, for a parent whose own Vision model went stale.
if CommandLine.arguments.dropFirst().first == VisionTextRecognizer.childArgument {
    exit(VisionTextRecognizer.serveChild())
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
