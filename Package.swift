// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "AudioStreaming",
    platforms: [
        .iOS(.v12),
    ],
    products: [
        .library(
            name: "AudioStreaming",
            targets: ["AudioStreaming"]
        ),
    ],
    targets: [
        .target(
            name: "AudioStreaming",
            dependencies: []
        ),
    ],
    swiftLanguageVersions: [.v5]
)
