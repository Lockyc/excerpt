// swift-tools-version: 6.0
import PackageDescription

// ExcerptCore, ExcerptExport and ExcerptRecording are pure of AppKit and build in Swift 6 mode.
// The AppKit / ScreenCaptureKit targets use Swift 5 mode: their APIs hand non-Sendable CF and
// AppKit types across callbacks, and strict isolation there buys annotations, not safety.
let package = Package(
    name: "excerpt",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "ExcerptCore"),
        .target(name: "ExcerptRecording", dependencies: ["ExcerptCore"]),
        .target(
            name: "ExcerptCapture",
            dependencies: ["ExcerptCore", "ExcerptRecording"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ExcerptEditor",
            dependencies: ["ExcerptCore", "ExcerptRecording"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "ExcerptExport", dependencies: ["ExcerptCore"]),
        .executableTarget(
            name: "Excerpt",
            dependencies: [
                "ExcerptCore", "ExcerptCapture", "ExcerptEditor", "ExcerptExport",
                "ExcerptRecording", .product(name: "Sparkle", package: "Sparkle"),
            ],
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
            dependencies: ["ExcerptCapture", "ExcerptEditor", "ExcerptTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ExcerptEditorTests",
            dependencies: ["ExcerptEditor", "ExcerptTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ExcerptExportTests", dependencies: ["ExcerptExport", "ExcerptTestSupport"]),
        .testTarget(
            name: "ExcerptRecordingTests",
            dependencies: ["ExcerptRecording", "ExcerptCore", "ExcerptTestSupport"]),
    ]
)
