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
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        ),
    ]
)
