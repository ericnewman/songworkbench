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
            name: "SongWorkbenchiPad",
            destinations: [.iPad],
            product: .app,
            bundleId: "com.local.SongWorkbench.iPad",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "SongWorkbench",
                "LSApplicationCategoryType": "public.app-category.music",
                "NSMicrophoneUsageDescription":
                    "SongWorkbench uses audio input for music analysis.",
                "NSAppleMusicUsageDescription":
                    "SongWorkbench reads your Music library so you can open and analyze local tracks.",
                // Required on iOS; an empty launch-screen dictionary uses the app's background.
                "UILaunchScreen": [:],
                // Landscape-only (2026-07-06): the 3-column desktop-style layout (song
                // list / editor / stem mixer) doesn't reflow for portrait width yet —
                // confirmed on an iPad Pro 13" simulator (columns clipped off-screen,
                // labels truncated). Revisit once the layout adapts responsively; until
                // then, don't offer an orientation the app can't actually render in.
                "UISupportedInterfaceOrientations": [
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                // Let users pull songs in via the Files app.
                "UIFileSharingEnabled": true,
                "LSSupportsOpeningDocumentsInPlace": true,
            ]),
            sources: ["Sources/SongWorkbench/**"],
            resources: ["Resources/**"],
            // No .entitlements file: the macOS one is app-sandbox/app-scope-bookmark
            // specific; iOS gets its sandbox implicitly and (for now) needs no extra
            // entitlements. Add an iOS-specific file here when iCloud/documents land.
            dependencies: [
                .package(product: "FluidAudio"),
                .package(product: "onnxruntime"),
                .package(product: "WhisperFramework"),
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "CODE_SIGN_STYLE": "Automatic",
                "CURRENT_PROJECT_VERSION": "1",
                "DEVELOPMENT_TEAM": "65FBMF6CMD",
                "GENERATE_INFOPLIST_FILE": "YES",
                "MARKETING_VERSION": "1.0",
                "SWIFT_VERSION": "6.0",
                "TARGETED_DEVICE_FAMILY": "2",
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
        .scheme(
            name: "SongWorkbenchiPad",
            shared: true,
            buildAction: .buildAction(targets: ["SongWorkbenchiPad"]),
            runAction: .runAction(configuration: .debug)
        ),
    ]
)
