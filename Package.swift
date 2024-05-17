// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "AudioStreaming",
    platforms: [
        .iOS(.v12),
        .macOS(.v13)
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
            path: "AudioStreaming"
        ),
        .testTarget(
            name: "AudioStreamingTests",
            dependencies: [
                "AudioStreaming"
            ],
            path: "AudioStreamingTests",
            resources: [
                .copy("Streaming/Metadata Stream Processor/raw-audio-streams/raw-stream-audio-empty-metadata"),
                .copy("Streaming/Metadata Stream Processor/raw-audio-streams/raw-stream-audio-no-metadata"),
                .copy("Streaming/Metadata Stream Processor/raw-audio-streams/raw-stream-audio-normal-metadata"),
                .copy("Streaming/Metadata Stream Processor/raw-audio-streams/raw-stream-audio-normal-metadata-alt")
          ]
        )
    ]
)
