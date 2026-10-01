import CoreGraphics
import CoreImage
import Foundation

actor WeMMEmbeddingProvider: TextEmbeddingProvider {
    static let shared = WeMMEmbeddingProvider()
    static let dimension = SearchIndexConfig.embeddingDimension
    static let framesPerClip = 4

    struct Availability: Sendable {
        private(set) var generation = 0
        private(set) var isAvailable = true

        @discardableResult
        mutating func update(isAvailable: Bool, generation: Int) -> Bool {
            guard generation > self.generation else { return false }
            self.generation = generation
            self.isAvailable = isAvailable
            return true
        }

        func accepts(_ generation: Int) -> Bool {
            isAvailable && self.generation == generation
        }
    }

    private var availability = Availability()
    #if BUNDLED_SPEECH
    private var runtime: WeMMEmbeddingRuntime?
    #endif

    private init() {}

    func encodeText(_ text: String) async throws -> [Float] {
        #if BUNDLED_SPEECH
        return try await encode { runtime in
            try await runtime.encode(text: text, dimension: Self.dimension)
        }
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    func encodeImage(_ image: CGImage) async throws -> [Float] {
        #if BUNDLED_SPEECH
        return try await encode { runtime in
            try await runtime.encode(image: CIImage(cgImage: image), dimension: Self.dimension)
        }
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    func encodeVideo(url: URL, range: ClosedRange<Double>, text: String?) async throws -> [Float] {
        #if BUNDLED_SPEECH
        return try await encode { runtime in
            try await runtime.encode(
                videoURL: url, timeRange: range, text: text, dimension: Self.dimension
            )
        }
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    func prepare() async throws {
        #if BUNDLED_SPEECH
        guard availability.isAvailable, runtime == nil,
              LocalModelManager.isInstalled(SearchIndexConfig.model) else { return }
        _ = try await encodeText("warm up")
        #endif
    }

    func resume(generation: Int) {
        availability.update(isAvailable: true, generation: generation)
    }

    func suspend(generation: Int) async throws {
        guard availability.update(isAvailable: false, generation: generation) else { return }
        await releaseResidentModel()
    }

    func releaseResidentModel() async {
        #if BUNDLED_SPEECH
        guard runtime != nil else { return }
        guard MLXRuntime.isAvailable else {
            runtime = nil
            return
        }
        do {
            try await MLXRuntime.beginInference()
        } catch {
            return
        }
        runtime = nil
        MLXRuntime.releaseActivations()
        MLXRuntime.endInference()
        #endif
    }

    #if BUNDLED_SPEECH
    private func encode(
        _ operation: @Sendable (WeMMEmbeddingRuntime) async throws -> [Float]
    ) async throws -> [Float] {
        let expectedGeneration = availability.generation
        try validate(expectedGeneration)
        try await LocalSpeechScheduler.shared.beginForeignInference()
        let result: Result<[Float], Error>
        do {
            result = .success(try await encodeHoldingInference(operation, expectedGeneration: expectedGeneration))
        } catch {
            result = .failure(error)
        }
        await LocalSpeechScheduler.shared.endForeignInference()
        return try result.get()
    }

    private func encodeHoldingInference(
        _ operation: @Sendable (WeMMEmbeddingRuntime) async throws -> [Float],
        expectedGeneration: Int
    ) async throws -> [Float] {
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }
        try validate(expectedGeneration)
        let runtime = try await loaded()
        try validate(expectedGeneration)
        let embedding = try await operation(runtime)
        try validate(expectedGeneration)
        return embedding
    }

    private func validate(_ expectedGeneration: Int) throws {
        try Task.checkCancellation()
        guard availability.accepts(expectedGeneration) else { throw CancellationError() }
    }

    private func loaded() async throws -> WeMMEmbeddingRuntime {
        if let runtime { return runtime }
        guard LocalModelManager.isInstalled(SearchIndexConfig.model) else {
            throw LocalAIError.incompleteModel("smart search resources")
        }
        let directory = try LocalModelManager.directory(for: SearchIndexConfig.modelID)
        let loaded = try await WeMMEmbeddingRuntime.load(from: directory, maxFrames: Self.framesPerClip)
        runtime = loaded
        return loaded
    }
    #endif
}
