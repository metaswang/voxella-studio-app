// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PalmierPro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PalmierPro", targets: ["PalmierPro"]),
    ],
    traits: [
        .trait(name: "BundledSpeech", description: "Include on-device speech models and MLX."),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/clerk/clerk-convex-swift", from: "0.1.0"),
        .package(url: "https://github.com/clerk/clerk-ios", from: "1.2.1"),
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.5"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.21"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            revision: "4266f988d170a83017d1e82e2e4654602f277f1d"
        ),
    ],
    targets: [
        .executableTarget(
            name: "PalmierPro",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ClerkConvex", package: "clerk-convex-swift"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ConvexMobile", package: "convex-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(
                    name: "MLX",
                    package: "mlx-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "SpeechEnhancement",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "SpeechVAD",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "AudioCommon",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "Qwen3ASR",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "Qwen3TTS",
                    package: "speech-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXAudioCore",
                    package: "mlx-audio-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXAudioSTT",
                    package: "mlx-audio-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXAudioLID",
                    package: "mlx-audio-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXAudioVAD",
                    package: "mlx-audio-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "HuggingFace",
                    package: "swift-huggingface",
                    condition: .when(traits: ["BundledSpeech"])
                ),
            ],
            path: "Sources/PalmierPro",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
                "Resources/Changelog",
                "App/Updater.swift",
                "App/UpdateBadgeView.swift",
                "App/Changelog.swift",
                "Home/UpdateOverlay.swift",
                "Home/WelcomeOverlay.swift",
            ],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/palmier-pro.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Localization"),
                .copy("Resources/Models"),
            ],
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
            ],
            plugins: ["MetalCIKernelPlugin"]
        ),
        .plugin(name: "MetalCIKernelPlugin", capability: .buildTool()),
        .testTarget(
            name: "PalmierProTests",
            dependencies: [
                "PalmierPro",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Tests/PalmierProTests",
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
            ]
        ),
    ]
)
