// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoxstudioPro",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "VoxStudio", targets: ["VoxstudioPro"]),
    ],
    traits: [
        .trait(name: "BundledSpeech", description: "Include on-device speech models and MLX."),
        .trait(name: "SparkleUpdates", description: "Link Sparkle.framework for in-app updates in direct distribution builds."),
        .trait(name: "MacAppStore", description: "Build the Mac App Store purchase surface."),
    ],
    dependencies: [
        .package(path: "Vendor/swift-sdk"),
        .package(url: "https://github.com/get-convex/convex-swift", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0"),
        // Keep this small local patch so unexpected YouTube player JS is surfaced
        // as an extraction error instead of terminating the app via fatalError.
        .package(path: "Vendor/YouTubeKit"),
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.21"),
        .package(path: "Vendor/FluidAudioVAD"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(path: "Vendor/mlx-audio-swift"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .executableTarget(
            name: "VoxstudioPro",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
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
                    name: "MLXHuggingFace",
                    package: "mlx-swift-lm",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "MLXVLM",
                    package: "mlx-swift-lm",
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
                    name: "MLXAudioSTS",
                    package: "mlx-audio-swift",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "HuggingFace",
                    package: "swift-huggingface",
                    condition: .when(traits: ["BundledSpeech"])
                ),
                .product(
                    name: "Sparkle",
                    package: "Sparkle",
                    condition: .when(traits: ["SparkleUpdates"])
                ),
                "CSQLiteVec",
            ],
            path: "Sources/VoxstudioPro",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/AppIcon.icns",
            ],
            resources: [
                .copy("Resources/AppIcon.png"),
                .copy("Resources/StatusBarIcon.svg"),
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/voxstudio.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Localization"),
                .copy("Resources/Models"),
                .copy("Resources/MCPApps"),
                .copy("Resources/KnowledgeSkills"),
            ],
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
                .define("SPARKLE_UPDATES", .when(traits: ["SparkleUpdates"])),
                .define("MAC_APP_STORE", .when(traits: ["MacAppStore"])),
            ],
            linkerSettings: [
                // SwiftUI VideoPlayer crashes without an explicit AVKit link in non-debugger launches.
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("IOKit"),
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
            name: "VoxstudioProTests",
            dependencies: [
                "VoxstudioPro",
                "CSQLiteVec",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Tests/VoxstudioProTests",
            swiftSettings: [
                .define("BUNDLED_SPEECH", .when(traits: ["BundledSpeech"])),
                .define("SPARKLE_UPDATES", .when(traits: ["SparkleUpdates"])),
                .define("MAC_APP_STORE", .when(traits: ["MacAppStore"])),
            ]
        ),
    ]
)
