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
                // The native Core ML six-stem model is gitignored (172 MB), so it can't be a
                // declared resource. Without it the app silently falls back to ONNX separation.
                // This phase was hand-added to the pbxproj once and lost on regeneration; keep it
                // here so `tuist generate` preserves it.
                .post(
                    script: """
                        if [ -d "$SRCROOT/BundledModels/HTDemucs6S_FP16.mlpackage" ]; then
                          rsync -a --delete "$SRCROOT/BundledModels/HTDemucs6S_FP16.mlpackage" "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
                        else
                          echo "warning: HTDemucs6S_FP16.mlpackage not present; app will use the ONNX separation path"
                        fi
                        """,
                    name: "Copy Bundled CoreML Model",
                    outputPaths: [
                        "$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HTDemucs6S_FP16.mlpackage"
                    ],
                    basedOnDependencyAnalysis: false
                )
            ],
            dependencies: [
                .package(product: "FluidAudio"),
                .package(product: "onnxruntime"),
                .package(product: "WhisperFramework"),
                .sdk(name: "AppIntents", type: .framework, status: .optional),
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER": "com.local.SongWorkbench",
                "CODE_SIGN_STYLE": "Automatic",
                "CURRENT_PROJECT_VERSION": "1",
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
