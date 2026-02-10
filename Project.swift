import ProjectDescription

let project = Project(
    name: "TenexLauncher",
    packages: [
        .remote(url: "https://github.com/onevcat/Kingfisher.git", requirement: .upToNextMajor(from: "8.1.0")),
    ],
    targets: [
        .target(
            name: "TenexLauncher",
            destinations: [.mac],
            product: .app,
            bundleId: "chat.tenex.launcher",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "TENEX",
                "LSUIElement": true,
                "TenexRepoRoot": "$(SRCROOT)",
            ]),
            sources: [
                .glob("Sources/TenexLauncher/**/*.swift"),
                // iOS app sources (exclude its @main App.swift — we provide our own)
                .glob(
                    "deps/tui/ios-app/Sources/TenexMVP/**/*.swift",
                    excluding: [
                        "deps/tui/ios-app/Sources/TenexMVP/App.swift",
                        "deps/tui/ios-app/Sources/TenexMVP/Services/DictationManager.swift",
                        "deps/tui/ios-app/Sources/TenexMVP/Views/DictationOverlayView.swift",
                        "deps/tui/ios-app/Sources/TenexMVP/Services/AudioNotificationPlayer.swift",
                    ]
                ),
                // Rust FFI swift bindings
                .glob("deps/tui/swift-bindings/tenex_core.swift"),
            ],
            resources: [
                "deps/tui/ios-app/Sources/TenexMVP/Resources/**",
            ],
            dependencies: [
                .package(product: "Kingfisher", type: .runtime),
            ],
            settings: .settings(
                base: [
                    "DEVELOPMENT_TEAM": "456SHKPP26",
                    "CODE_SIGN_STYLE": "Automatic",
                    // FFI header search paths
                    "HEADER_SEARCH_PATHS": [
                        "$(inherited)",
                        "$(SRCROOT)/deps/tui/ios-app/Sources/TenexMVP/TenexCoreFFI",
                    ],
                    // Rust static library for macOS
                    "LIBRARY_SEARCH_PATHS": [
                        "$(inherited)",
                        "$(SRCROOT)/deps/tui/target/aarch64-apple-darwin/release",
                    ],
                    "OTHER_LDFLAGS": [
                        "$(inherited)",
                        "$(SRCROOT)/deps/tui/target/aarch64-apple-darwin/release/libtenex_core.a",
                        "-framework", "SystemConfiguration",
                    ],
                    // Swift import paths for the modulemap
                    "SWIFT_INCLUDE_PATHS": [
                        "$(inherited)",
                        "$(SRCROOT)/deps/tui/ios-app/Sources/TenexMVP/TenexCoreFFI",
                        "$(SRCROOT)/Sources/UIKitShim", // UIKit shim modulemap for macOS
                    ],
                    "OTHER_SWIFT_FLAGS": [
                        "$(inherited)",
                        "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "UIUtilities",
                        "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "SwiftUICore",
                    ],
                ]
            )
        ),
    ]
)
