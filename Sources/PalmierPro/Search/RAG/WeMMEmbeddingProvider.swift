import Foundation

#if BUNDLED_SPEECH

actor WeMMEmbeddingProvider: TextEmbeddingProvider {
    static let dimension = 256
    static let framesPerClip = 4

    private var runtime: WeMMEmbeddingRuntime?

    func encodeText(_ text: String) async throws -> [Float] {
        try await loaded().encode(text: text, dimension: Self.dimension)
    }

    func encodeVideo(url: URL, range: ClosedRange<Double>, text: String?) async throws -> [Float] {
        try await loaded().encode(
            videoURL: url,
            timeRange: range,
            text: text,
            dimension: Self.dimension
        )
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
