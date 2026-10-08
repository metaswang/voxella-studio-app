import Foundation
import MLX

/// Offline eight-speaker activity for one recording using the pinned Nemotron 3
/// MLX INT8 export. Speaker channels are anonymous arrival-order labels within
/// that recording only.
///
/// Not thread-safe: callers serialize use (the app holds its MLX inference lock).
public final class Nemotron3Diarizer {
    public let geometry: Nemotron3Geometry
    private let backend: Nemotron3InferenceBackend
    private let melExtractor: Nemotron3MelExtractor
    private let updater: Nemotron3SpeakerCacheUpdater

    public var speakerCapacity: Int { geometry.speakerCount }
    public var frameDuration: Double { geometry.frameDuration }

    /// Loads an already-installed bundle (`config.json`, `model.safetensors`).
    public convenience init(modelDirectory: URL) throws {
        try self.init(backend: Nemotron3MLXBackend(directory: modelDirectory), geometry: .offline)
    }

    init(backend: Nemotron3InferenceBackend, geometry: Nemotron3Geometry) {
        self.backend = backend
        self.geometry = geometry
        melExtractor = Nemotron3MelExtractor(geometry: geometry)
        updater = Nemotron3SpeakerCacheUpdater(
            geometry: geometry, silenceEmbedding: backend.learnedSilenceEmbedding
        )
    }

    /// Returns `[frameCount(sampleCount:) * speakerCapacity]` activity probabilities
    /// at 10 ms, in audio order. State is reset for every call and carried across
    /// chunks within it.
    ///
    /// - Parameter onChunk: called after each chunk with (completed, total); throw
    ///   from it to cancel. No partial result is returned on cancellation.
    public func activityProbabilities(
        audio: [Float],
        onChunk: (Int, Int) throws -> Void = { _, _ in }
    ) throws -> [Float] {
        let frameCount = geometry.frameCount(sampleCount: audio.count)
        guard frameCount > 0 else { return [] }
        let totalChunks = geometry.chunkCount(sampleCount: audio.count)
        let stride = geometry.subsamplingFactor
        let dimension = geometry.modelDimension
        let speakers = geometry.speakerCount
        let fixedMelFrames = geometry.fixedChunkMelFrames
        let fixedRows = geometry.chunkLength + geometry.rightContext

        var state = Nemotron3SpeakerCacheState()
        var output: [Float] = []
        output.reserveCapacity(frameCount * speakers)
        var startFrame = 0
        var completed = 0

        while startFrame < frameCount {
            let endFrame = min(startFrame + geometry.chunkMelFrames, frameCount)
            let rightFrames = min(geometry.rightContextMelFrames, frameCount - endFrame)
            let validMelFrames = endFrame + rightFrames - startFrame

            var chunk = melExtractor.extract(audio: audio, frames: startFrame..<(startFrame + validMelFrames))
            chunk.append(contentsOf: repeatElement(0, count: (fixedMelFrames - validMelFrames) * geometry.melBins))
            let embeddings = try backend.preencode(chunk: chunk)
            guard embeddings.count == fixedRows * dimension else {
                throw Nemotron3DiarizationError.runtime("pre-encoder returned \(embeddings.count) values")
            }
            let validRows = min(fixedRows, (validMelFrames + stride - 1) / stride)
            let rightRows = (rightFrames + stride - 1) / stride
            let coreRows = validRows - rightRows

            var packed = [Float](repeating: 0, count: geometry.packedCapacity * dimension)
            var rows = 0
            func pack(_ source: [Float], count: Int) {
                guard count > 0 else { return }
                packed.replaceSubrange(rows * dimension..<(rows + count) * dimension,
                                       with: source[0..<(count * dimension)])
                rows += count
            }
            pack(state.cache, count: state.cacheLength)
            pack(state.fifo, count: state.fifoLength)
            let historyRows = rows
            pack(embeddings, count: validRows)

            let head = try backend.predictHead(packedEmbeddings: packed, validLength: rows)
            guard head.probabilities80ms.count == geometry.packedCapacity * speakers,
                  head.probabilities10ms.count == geometry.packedCapacity * stride * speakers else {
                throw Nemotron3DiarizationError.runtime("head returned an unexpected output shape")
            }

            let emitted = endFrame - startFrame
            let highStart = historyRows * stride * speakers
            output.append(contentsOf: head.probabilities10ms[highStart..<(highStart + emitted * speakers)])
            updater.update(
                state: &state,
                coreEmbeddings: Array(embeddings[0..<(coreRows * dimension)]),
                predictions: head.probabilities80ms
            )
            Memory.clearCache()
            startFrame = endFrame
            completed += 1
            try onChunk(completed, totalChunks)
        }
        return output
    }
}
