// swift-tools-version: 6.2

import PackageDescription

// VAD-only slice of FluidInference/FluidAudio 0.15.6 (MIT).
// The full SDK links NemoTextProcessing, which collides with Convex's Rust staticlib.
let package = Package(
    name: "FluidAudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FluidAudio", targets: ["FluidAudio"]),
    ],
    targets: [
        .target(
            name: "FluidAudio",
            path: "Sources/FluidAudio"
        ),
    ]
)
