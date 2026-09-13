import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PalmierPro

@Suite("Visual indexing with shared search embeddings")
struct VisualIndexerTests {
    private static let spec = SearchIndexConfig.visualSpec

    #if BUNDLED_SPEECH
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_WEMM_SEARCH_INTEGRATION"] == "1"))
    func realWeMMImageIndexAndSharedTextQuery() async throws {
        try await withImage { url, key in
            try #require(MLXRuntime.isAvailable)
            try #require(LocalModelManager.isInstalled(SearchIndexConfig.model))
            try await VisualIndexer.indexImage(url: url, model: .weMM)
            let index = try EmbeddingStore.load(key: key)
            let sessionVector = try await WeMMEmbeddingProvider.shared.encodeText("a plain red image")
            let visualVector = try await VisualEmbedder.weMM.encode(text: "a plain red image")
            #expect(sessionVector == visualVector)
            #expect(sessionVector.count == SearchIndexConfig.embeddingDimension)
            #expect(sessionVector.allSatisfy { $0.isFinite })
            #expect(Self.spec.matches(index.header))
            let hits = VisualSearch.search(query: visualVector, indexes: [("red-image", index)])
            #expect(hits.first?.assetID == "red-image")
        }
    }
    #endif

    @Test func replacesSigLIPIndexWithWeMMAndSkipsRepeatedWork() async throws {
        try await withImage { url, key in
            try EmbeddingStore.save(
                header: .init(model: "siglip2-base-patch16-256", modelVersion: 1,
                              samplerVersion: FrameSampler.samplerVersion, dim: 768, count: 1),
                rows: [.init(time: 0, shotStart: 0, shotEnd: 0)],
                vectors: Array(repeating: 0.1, count: 768), key: key
            )
            #expect(VisualIndexer.needsIndex(url: url, spec: Self.spec))
            try await VisualIndexer.indexImage(url: url, model: Self.model())
            let index = try EmbeddingStore.load(key: key)
            #expect(Self.spec.matches(index.header))
            #expect(index.rows.count == 1)
            #expect(index.vectors.count == SearchIndexConfig.embeddingDimension)
            #expect(!VisualIndexer.needsIndex(url: url, spec: Self.spec))
            try await VisualIndexer.indexImage(url: url, model: Self.model {
                Issue.record("Current index must not trigger inference")
                throw CancellationError()
            })
        }
    }

    @Test func cancelledInferenceDoesNotCommitIndex() async throws {
        try await withImage { url, key in
            let gate = InferenceGate()
            let task = Task {
                try await VisualIndexer.indexImage(url: url, model: Self.model {
                    await gate.enter()
                    return Self.vector()
                })
            }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(EmbeddingStore.header(key: key) == nil)
        }
    }

    @Test func changedSourceDuringInferenceDoesNotCommitIndex() async throws {
        try await withImage { url, key in
            await #expect(throws: VisualIndexer.IndexError.self) {
                try await VisualIndexer.indexImage(url: url, model: Self.model {
                    try Data("changed source".utf8).write(to: url)
                    return Self.vector()
                })
            }
            #expect(EmbeddingStore.header(key: key) == nil)
        }
    }

    @Test(arguments: [[], [Float.nan], [Float.infinity], [Float(0)]])
    func invalidEmbeddingDoesNotCommitIndex(values: [Float]) async throws {
        let embedding = values.first.map { Array(repeating: $0, count: Self.spec.embeddingDim) } ?? []
        try await withImage { url, key in
            await #expect(throws: VisualIndexer.IndexError.self) {
                try await VisualIndexer.indexImage(url: url, model: Self.model { embedding })
            }
            #expect(EmbeddingStore.header(key: key) == nil)
        }
    }

    @Test func sampledVideoRetainsSourceShotRangesWithWeMMVectors() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 10),
            .init(rgb: (30, 200, 30), seconds: 10)
        ])
        let key = try #require(EmbeddingStore.key(for: url))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
        }
        try await VisualIndexer.index(url: url, duration: 20, model: Self.model())
        let index = try EmbeddingStore.load(key: key)
        #expect(Self.spec.matches(index.header))
        #expect(index.rows.count >= 2)
        let query = try await Self.model().encode(text: "a scene")
        let hits = VisualSearch.search(query: query, indexes: [("fixture", index)])
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.shotStart >= 0 && $0.shotEnd <= 20 && $0.shotStart < $0.shotEnd })
    }

    @Test func undecodableImageReportsFailureWithoutSuccessfulIndex() async throws {
        try await withImage { url, _ in
            try Data("not an image".utf8).write(to: url)
            let key = try #require(EmbeddingStore.key(for: url))
            await #expect(throws: VisualIndexer.IndexError.self) {
                try await VisualIndexer.indexImage(url: url, model: Self.model())
            }
            #expect(EmbeddingStore.header(key: key) == nil)
        }
    }

    @Test func mismatchedRevisionDimensionAndSamplerAreRejected() {
        let current = EmbeddingStore.Header(
            model: Self.spec.model, modelVersion: Self.spec.version,
            samplerVersion: FrameSampler.samplerVersion, dim: Self.spec.embeddingDim, count: 1
        )
        #expect(Self.spec.matches(current))
        for header in [
            EmbeddingStore.Header(model: "old-revision", modelVersion: Self.spec.version,
                                  samplerVersion: FrameSampler.samplerVersion, dim: Self.spec.embeddingDim, count: 1),
            .init(model: Self.spec.model, modelVersion: Self.spec.version + 1,
                  samplerVersion: FrameSampler.samplerVersion, dim: Self.spec.embeddingDim, count: 1),
            .init(model: Self.spec.model, modelVersion: Self.spec.version,
                  samplerVersion: FrameSampler.samplerVersion, dim: 768, count: 1),
            .init(model: Self.spec.model, modelVersion: Self.spec.version,
                  samplerVersion: FrameSampler.samplerVersion + 1, dim: Self.spec.embeddingDim, count: 1)
        ] {
            #expect(!Self.spec.matches(header))
        }
    }

    private static func vector() -> [Float] {
        [1] + Array(repeating: 0, count: spec.embeddingDim - 1)
    }

    private static func model(
        image: @escaping @Sendable () async throws -> [Float] = { vector() }
    ) -> VisualEmbedder {
        VisualEmbedder(spec: spec, encodeImage: { _ in try await image() }, encodeText: { _ in vector() })
    }

    @concurrent private func withImage(
        _ operation: @Sendable (URL, String) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).png")
        try Self.writePNG(to: url)
        let key = try #require(EmbeddingStore.key(for: url))
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: EmbeddingStore.diskURL(key))
        }
        try await operation(url, key)
    }

    private static func writePNG(to url: URL) throws {
        let size = 64
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

private actor InferenceGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { completion = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }

    func release() {
        completion?.resume()
        completion = nil
    }
}
