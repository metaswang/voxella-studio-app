import Foundation

#if BUNDLED_SPEECH

actor WeMMEmbeddingProvider: TextEmbeddingProvider {
    static let dimension = 256
    static let framesPerClip = 4

    private var runtime: WeMMEmbeddingRuntime?

    func encodeText(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        let runtime = try await loaded()
        try Task.checkCancellation()
        let embedding = try await runtime.encode(text: text, dimension: Self.dimension)
        try Task.checkCancellation()
        return embedding
    }

    func encodeVideo(url: URL, range: ClosedRange<Double>, text: String?) async throws -> [Float] {
        try Task.checkCancellation()
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        let runtime = try await loaded()
        try Task.checkCancellation()
        let embedding = try await runtime.encode(
            videoURL: url,
            timeRange: range,
            text: text,
            dimension: Self.dimension
        )
        try Task.checkCancellation()
        return embedding
    }

    func prepare() async throws {
        guard let descriptor = LocalModelManager.catalog.first(where: { $0.id == .weMMEmbedding2B4Bit }),
              LocalModelManager.isInstalled(descriptor),
              runtime == nil else { return }
        try Task.checkCancellation()
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        let runtime = try await loaded()
        try Task.checkCancellation()
        _ = try await runtime.encode(text: "warm up", dimension: Self.dimension)
        try Task.checkCancellation()
    }

    private func loaded() async throws -> WeMMEmbeddingRuntime {
        if let runtime { return runtime }
        let directory = try LocalModelManager.directory(for: .weMMEmbedding2B4Bit)
        let loaded = try await WeMMEmbeddingRuntime.load(
            from: directory,
            maxFrames: Self.framesPerClip
        )
        runtime = loaded
        return loaded
    }
}

#endif
