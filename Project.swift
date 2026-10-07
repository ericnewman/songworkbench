import ProjectDescription

let project = Project(
    name: "SongWorkbench",
    organizationName: "CCS",
    packages: [
        .remote(
            url: "https://github.com/FluidInference/FluidAudio.git",
            requirement: .exact("0.15.4")
        ),
        .remote(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
            requirement: .exact("1.24.2")
        ),
        .local(path: "Dependencies/WhisperFramework"),
        // Qwen3-ASR on MLX: a trimmed local copy of mlx-audio-swift (see its Package.swift).
        .local(path: "Dependencies/MLXAudioQwen3"),
    ],
    targets: [
        .target(
            name: "SongWorkbench",
            destinations: .macOS,
            product: .app,
            bundleId: "$(SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER)",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "SongWorkbench",
                "LSApplicationCategoryType": "public.app-category.music",
                "NSHighResolutionCapable": true,
                "NSMicrophoneUsageDescription":
                    "SongWorkbench uses audio input for music analysis.",
                "NSAppleMusicUsageDescription":
                    "SongWorkbench reads your Music library so you can open and analyze local tracks.",
            ]),
            sources: ["Sources/SongWorkbench/**"],
            resources: ["Resources/**"],
            entitlements: .file(path: "SongWorkbench.entitlements"),
            scripts: [
                // The bundled Core ML models are gitignored (172 MB), so they can't be declared
                // resources. The app does not run without them (Eric, 2026-09-26: no fallback), so a
                // missing model fails the build instead of producing an app that silently degrades.
                // This phase was hand-added to the pbxproj once and lost on regeneration; keep it
                // here so `tuist generate` preserves it.
                .post(
                    script: """
                        for m in HTDemucs6S_FP16 LyricsAlignmentMTL BeatThis ChordNet; do
                          if [ -d "$SRCROOT/BundledModels/$m.mlpackage" ]; then
                            rsync -a --delete "$SRCROOT/BundledModels/$m.mlpackage" "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
                          else
                            echo "error: BundledModels/$m.mlpackage is missing. SongWorkbench does not run without its models; copy BundledModels/ from the main checkout."
                            exit 1
                          fi
                        done
                        """,
                    name: "Copy Bundled CoreML Model",
                    outputPaths: [
                        "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HTDemucs6S_FP16.mlpackage",
                        "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/LyricsAlignmentMTL.mlpackage",
                        "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/BeatThis.mlpackage",
                        "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ChordNet.mlpackage",
                    ],
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [
                .package(product: "FluidAudio"),
                .package(product: "onnxruntime"),
                .package(product: "WhisperFramework"),
                .package(product: "MLXAudioQwen3"),
                .sdk(name: "AppIntents", type: .framework, status: .optional),
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER": "com.local.SongWorkbench",
                "CODE_SIGN_STYLE": "Automatic",
                "CURRENT_PROJECT_VERSION": "1",
                // The Copy Bundled CoreML Model phase rsyncs a whole .mlpackage directory; Xcode's
                // script sandbox only grants the literal declared paths, never their contents.
                // It is this target's only script phase.
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                "GENERATE_INFOPLIST_FILE": "YES",
                "MARKETING_VERSION": "1.0",
                "SWIFT_VERSION": "6.0",
            ], debug: [
                // Sign + sandbox Debug (like Release) so a STABLE identity makes macOS remember the
                // network/removable-volume privacy grant across launches. The sandbox relocates the
                // app's data to its container, so the existing ~/Library/Application Support data
                // (models, caches, projects) must be copied into the container once — see the
                // one-time migration the user runs after `tuist generate` + first launch.
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                // The TEAM ID is the certificate's OU (65FBMF6CMD), NOT the parenthetical in the
                // certificate name (94276EJ325 — that's the cert identifier). With the wrong value
                // here, every `tuist generate` regenerated a team Xcode couldn't resolve and
                // signing had to be re-picked by hand in Xcode, only to be stomped again.
                "DEVELOPMENT_TEAM": "65FBMF6CMD",
                "ENABLE_APP_SANDBOX": "YES",
            ], release: [
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "Apple Distribution",
                "DEVELOPMENT_TEAM": "$(SONGWORKBENCH_DEVELOPMENT_TEAM)",
                "ENABLE_APP_SANDBOX": "YES",
                "ENABLE_HARDENED_RUNTIME": "YES",
            ])
        ),
        .target(
            name: "SongWorkbenchTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.local.SongWorkbenchTests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/SongWorkbenchTests/**"],
            dependencies: [
                .target(name: "SongWorkbench"),
                .sdk(name: "AppIntents", type: .framework, status: .optional),
            ],
            settings: .settings(base: [
                "CODE_SIGNING_ALLOWED": "NO",
                "SWIFT_VERSION": "6.0",
            ])
        ),
    ],
    schemes: [
        .scheme(
            name: "SongWorkbench",
            shared: true,
            buildAction: .buildAction(targets: ["SongWorkbench"]),
            testAction: .targets(["SongWorkbenchTests"]),
            runAction: .runAction(configuration: .debug),
            archiveAction: .archiveAction(configuration: .release)
        ),
    ]
)
