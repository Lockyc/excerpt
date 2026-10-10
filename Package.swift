// swift-tools-version: 6.0
import PackageDescription

// ExcerptCore is pure and builds in Swift 6 mode. The AppKit / ScreenCaptureKit targets use
// Swift 5 mode: their APIs hand non-Sendable CF and AppKit types across callbacks, and strict
// isolation there buys annotations, not safety.
let package = Package(
    name: "excerpt",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ExcerptCore"),
        .target(
            name: "ExcerptCapture",
            dependencies: ["ExcerptCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ExcerptEditor",
            dependencies: ["ExcerptCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Excerpt",
            dependencies: ["ExcerptCore", "ExcerptCapture", "ExcerptEditor"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ExcerptTestSupport", dependencies: ["ExcerptCore"],
            path: "Tests/ExcerptTestSupport"),
        .testTarget(
            name: "ExcerptCoreTests", dependencies: ["ExcerptCore", "ExcerptTestSupport"],
            exclude: ["Goldens"]),
        .testTarget(
            name: "ExcerptCaptureTests",
            dependencies: ["ExcerptCapture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ExcerptEditorTests",
            dependencies: ["ExcerptEditor", "ExcerptTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
