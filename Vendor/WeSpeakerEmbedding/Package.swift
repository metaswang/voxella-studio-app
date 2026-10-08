// swift-tools-version: 6.2

import PackageDescription

// WeSpeaker ResNet34-LM network extracted from soniqo/speech-swift (Apache-2.0),
// with a Kaldi FBank front end and unbiased statistics pooling that match the
// pyannote/WeSpeaker reference implementation. Weights are unchanged.
let package = Package(
    name: "WeSpeakerEmbedding",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WeSpeakerEmbedding", targets: ["WeSpeakerEmbedding"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.0")),
    ],
    targets: [
        .target(
            name: "WeSpeakerEmbedding",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WeSpeakerEmbeddingTests",
            dependencies: ["WeSpeakerEmbedding"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
