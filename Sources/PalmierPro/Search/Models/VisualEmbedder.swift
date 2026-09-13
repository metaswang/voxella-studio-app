import CoreGraphics
import Foundation

struct VisualEmbedder: Sendable {
    struct Spec: Codable, Equatable, Sendable {
        let model: String
        let version: Int
        let embeddingDim: Int

        func matches(_ header: EmbeddingStore.Header) -> Bool {
            header.model == model && header.modelVersion == version
                && header.dim == embeddingDim && header.samplerVersion == FrameSampler.samplerVersion
        }
    }

    let spec: Spec
    let encodeImage: @Sendable (CGImage) async throws -> [Float]
    let encodeText: @Sendable (String) async throws -> [Float]

    static let weMM = VisualEmbedder(
        spec: SearchIndexConfig.visualSpec,
        encodeImage: { try await WeMMEmbeddingProvider.shared.encodeImage($0) },
        encodeText: { try await WeMMEmbeddingProvider.shared.encodeText($0) }
    )

    func encode(image: CGImage) async throws -> [Float] {
        try await encodeImage(image)
    }

    func encode(text: String) async throws -> [Float] {
        try await encodeText(text)
    }
}
