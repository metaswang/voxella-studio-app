// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SortformerReplay",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Vendor/mlx-audio-swift"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.5"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
    ],
    targets: [.executableTarget(name: "SortformerReplay", dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
    ]), .testTarget(name: "SortformerRegressionTests", dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
    ])]
)
