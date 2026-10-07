// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhisperFramework",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WhisperFramework", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        )
    ]
)
