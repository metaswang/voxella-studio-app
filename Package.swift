// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PalmierPro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VoxStudio", targets: ["PalmierPro"]),
    ],
    traits: [
        .trait(name: "BundledSpeech", description: "Include on-device speech models and MLX."),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "9.1.0"),
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0"),
        .package(url: "https://github.com/alexeichhorn/YouTubeKit.git", from: "0.4.9"),
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.21"),
        .package(path: "Vendor/FluidAudioVAD"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(path: "Vendor/mlx-audio-swift"),
    ],
    targets: [
        .executableTarget(
            name: "PalmierPro",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "ConvexMobile", package: "convex-swift"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "Textual", package: "textual"),
                .product(name: "YouTubeKit", package: "YouTubeKit"),
                .product(
                    name: "MLX",
                    package: "mlx-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXLMCommon",
                    package: "mlx-swift-lm",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXVLM",
                    package: "mlx-swift-lm",
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
                    name: "FluidAudio",
                    package: "FluidAudioVAD",
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
                    name: "MLXAudioTTS",
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
                "CSQLiteVec",
            ],
            path: "Sources/PalmierPro",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
            ],
            resources: [
                .copy("Resources/AppIcon.png"),
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/palmier-pro.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Localization"),
                .copy("Resources/Models"),
            ],
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
            ],
            linkerSettings: [
                // SwiftUI VideoPlayer crashes without an explicit AVKit link in non-debugger launches.
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("AuthenticationServices"),
                .linkedLibrary("sqlite3"),
            ],
            plugins: ["MetalCIKernelPlugin"]
        ),
        .target(
            name: "CSQLiteVec",
            path: "Vendor/sqlite-vec",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .define("SQLITE_VEC_OMIT_FS"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .plugin(name: "MetalCIKernelPlugin", capability: .buildTool()),
        .testTarget(
            name: "PalmierProTests",
            dependencies: [
                "PalmierPro",
                "CSQLiteVec",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Tests/PalmierProTests",
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
            ]
        ),
    ]
)
