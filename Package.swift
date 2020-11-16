//
//  Created by Dimitrios Chatzieleftheriou on 16/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

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
            path: "AudioStreaming"
        ),
    ]
)
