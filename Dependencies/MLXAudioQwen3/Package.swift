// swift-tools-version: 6.2

import PackageDescription

// A trimmed copy of mlx-audio-swift (https://github.com/Blaizzy/mlx-audio-swift, commit
// b7c7971d94c4f73de910797593851d00858daf19 of 2026-09-29, MIT — see LICENSE): MLXAudioCore and the
// Qwen3-ASR model only. That commit carries the mel-frontend fix (Slaney mel scale, periodic Hann
// window, #247) without which Qwen3-ASR scored 0.764 word recall on Doc Holiday instead of ~0.85.
// Vendored because the upstream package does not compile under the Swift 6.4 compiler
// (strict-concurrency errors in its Parakeet model, which this app does not use) and sets
// unsafeFlags, which SwiftPM refuses from a version-pinned dependency. Swift 5 language mode.
let package = Package(
    name: "MLXAudioQwen3",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MLXAudioQwen3", targets: ["MLXAudioCore", "MLXAudioSTT"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "MLXAudioCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/MLXAudioCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MLXAudioSTT",
            dependencies: [
                "MLXAudioCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/MLXAudioSTT",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
