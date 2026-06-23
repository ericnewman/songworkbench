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
                "CODE_SIGNING_ALLOWED": "NO"
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
        )
    ]
)
