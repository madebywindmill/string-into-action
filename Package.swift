// swift-tools-version: 6.0
import PackageDescription

// Headless tests for scanning, editing, and review state; the UI builds with Xcode.
let package = Package(
    name: "StringIntoAction",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "StringIntoAction", path: "StringIntoAction",
                exclude: ["Views", "Assets.xcassets", "StringIntoActionApp.swift"]),
        .testTarget(name: "StringIntoActionTests", dependencies: ["StringIntoAction"],
                    path: "StringIntoActionTests")
    ]
)
