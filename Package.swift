// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SongWorkbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SongWorkbench", targets: ["SongWorkbench"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.4"
        ),
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            exact: "1.24.2"
        )
    ],
    targets: [
        .executableTarget(
            name: "SongWorkbench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                ),
                "WhisperFramework",
            ]
        ),
        .testTarget(
            name: "SongWorkbenchTests",
            dependencies: ["SongWorkbench"]
        ),
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        ),
    ]
)
