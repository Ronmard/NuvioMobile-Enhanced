// swift-tools-version: 6.0

import PackageDescription

// AetherEngine wrapped in its own dynamic framework.
//
// AetherEngine is a static SwiftPM product, and its FFmpeg exports the same C symbols as MPVKit's.
// Linked straight into the app executable, the engine's `_av*` references and the app's own
// (FFmpegSeekPreviewGenerator) would each bind to whichever FFmpeg links first. Inside this
// framework they resolve against the Aether-prefixed FFmpeg frameworks only; see "Holding a second
// player beside the engine" in AetherEngine's docs/api.md. The app talks to NuvioAetherKit alone and
// never imports AetherEngine, so its compile never loads the second set of FFmpeg C modules either.
let package = Package(
    name: "NuvioAetherKit",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(name: "NuvioAetherKit", type: .dynamic, targets: ["NuvioAetherKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/AetherEngine", "6.5.0"..<"7.0.0"),
    ],
    targets: [
        .target(
            name: "NuvioAetherKit",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Has the compiler verify that no AetherEngine type leaks through the public API
                // (the @_implementationOnly import is what keeps it out of the app module).
                .enableExperimentalFeature("CheckImplementationOnly"),
            ]
        ),
    ]
)
