// swift-tools-version:5.10

import PackageDescription

let package = Package(
    name: "AudioStreaming",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .tvOS(.v16)
    ],
    products: [
        .library(
            name: "AudioStreaming",
            targets: ["AudioCodecs", "AudioStreaming"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework", exact: "0.1.2"),
        .package(url: "https://github.com/sbooth/vorbis-binary-xcframework", exact: "0.1.2")
    ],
    targets: [
        // C target for audio codec bridges
        .target(
            name: "AudioCodecs",
            dependencies: [
                .product(name: "ogg", package: "ogg-binary-xcframework"),
                .product(name: "vorbis", package: "vorbis-binary-xcframework")
            ],
            path: "AudioCodecs",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Foundation")
            ]
        ),
        
        // Main Swift target
        .target(
            name: "AudioStreaming",
            dependencies: [
                "AudioCodecs",
                .product(name: "ogg", package: "ogg-binary-xcframework"),
                .product(name: "vorbis", package: "vorbis-binary-xcframework")
            ],
            path: "AudioStreaming",
            exclude: ["AudioStreaming.h", "Streaming/OggVorbis"],
            swiftSettings: []
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
