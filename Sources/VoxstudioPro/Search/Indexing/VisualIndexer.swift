import CoreGraphics
import Foundation
import ImageIO

/// Indexes one asset: sampled frames → embeddings → EmbeddingStore. Idempotent per (file, model, sampler).
enum VisualIndexer {
    enum IndexError: Error {
        case missingMedia, undecodableMedia, invalidVector, staleMedia, invalidDuration
    }

    static func needsIndex(url: URL, spec: VisualEmbedder.Spec) -> Bool {
        guard let key = EmbeddingStore.key(for: url),
              let header = EmbeddingStore.header(key: key) else { return true }
        return !spec.matches(header)
    }

    @concurrent static func index(
        url: URL,
        duration: Double,
        model: VisualEmbedder,
        options: FrameSampler.Options = .init(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard duration.isFinite, duration > 0 else { throw IndexError.invalidDuration }
        guard let key = EmbeddingStore.key(for: url) else { throw IndexError.missingMedia }
        let spec = model.spec
        guard needsIndex(url: url, spec: spec) else { return }

        var times: [Double] = []
        var shotIndices: [Int] = []
        var shotStarts: [Double] = []
        var vectors: [Float] = []

        try await FrameSampler.sample(url: url, duration: duration, options: options) { frame in
            try Task.checkCancellation()
            try await ExportQueue.shared.waitWhileExportActive()
            if frame.isNewShot {
                shotStarts.append(shotStarts.isEmpty ? 0 : frame.time)
            }
            let vector = try await model.encode(image: frame.image)
            try validate(vector, spec: spec)
            vectors += vector
            times.append(frame.time)
            shotIndices.append(shotStarts.count - 1)
            if duration > 0 { progress?(min(frame.time / duration, 1)) }
        }
        try Task.checkCancellation()
        guard !times.isEmpty else { throw IndexError.undecodableMedia }
        let rows = zip(times, shotIndices).map { time, shot in
            EmbeddingStore.Row(
                time: time,
                shotStart: shotStarts[shot],
                shotEnd: shot + 1 < shotStarts.count ? shotStarts[shot + 1] : duration
            )
        }
        guard EmbeddingStore.key(for: url) == key else { throw IndexError.staleMedia }
        try save(rows: rows, vectors: vectors, spec: spec, key: key)
    }

    /// Stills skip the sampler: one embedding, zero-length shot range.
    @concurrent static func indexImage(url: URL, model: VisualEmbedder) async throws {
        try Task.checkCancellation()
        guard let key = EmbeddingStore.key(for: url) else { throw IndexError.missingMedia }
        guard needsIndex(url: url, spec: model.spec) else { return }
        try await ExportQueue.shared.waitWhileExportActive()

        guard let image = decodeImage(url) else { throw IndexError.undecodableMedia }
        let vectors = try await model.encode(image: image)
        try validate(vectors, spec: model.spec)
        let rows = [EmbeddingStore.Row(time: 0, shotStart: 0, shotEnd: 0)]
        try Task.checkCancellation()
        guard EmbeddingStore.key(for: url) == key else { throw IndexError.staleMedia }
        try save(rows: rows, vectors: vectors, spec: model.spec, key: key)
    }

    private static func validate(_ vector: [Float], spec: VisualEmbedder.Spec) throws {
        guard vector.count == spec.embeddingDim, vector.allSatisfy(\.isFinite),
              vector.contains(where: { $0 != 0 }) else { throw IndexError.invalidVector }
    }

    private static func decodeImage(_ url: URL) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func save(rows: [EmbeddingStore.Row], vectors: [Float], spec: VisualEmbedder.Spec, key: String) throws {
        let header = EmbeddingStore.Header(
            model: spec.model, modelVersion: spec.version,
            samplerVersion: FrameSampler.samplerVersion,
            dim: spec.embeddingDim, count: rows.count
        )
        try EmbeddingStore.save(header: header, rows: rows, vectors: vectors, key: key)
    }
}
