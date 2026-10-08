// swift-tools-version: 6.2

import PackageDescription

// Nemotron 3 Diarization inference, DSP, and speaker-cache state extracted from
// soniqo/speech-swift v0.0.28 (commit 231f8eb9f0971fee335fef49f42d2975e4fbf8bc, Apache-2.0).
// Only the MLX INT8 path is kept; the rest of speech-swift stays at the app's pinned version.
let package = Package(
    name: "Nemotron3Diarization",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Nemotron3Diarization", targets: ["Nemotron3Diarization"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.0")),
    ],
    targets: [
        .target(
            name: "Nemotron3Diarization",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "Nemotron3DiarizationTests",
            dependencies: ["Nemotron3Diarization"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
