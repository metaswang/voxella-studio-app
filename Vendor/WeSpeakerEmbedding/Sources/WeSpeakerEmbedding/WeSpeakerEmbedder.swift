import Foundation
import MLX
import MLXNN

public enum WeSpeakerEmbeddingError: LocalizedError, Equatable {
    case missingWeights(String)
    case audioTooShort(minimumSamples: Int)
    case invalidAudio
    case invalidEmbedding

    public var errorDescription: String? {
        switch self {
        case .missingWeights(let path): "Speaker embedding weights are missing: \(path)"
        case .audioTooShort: "The audio is too short for a voiceprint."
        case .invalidAudio: "The audio contains invalid samples."
        case .invalidEmbedding: "The voiceprint could not be computed."
        }
    }
}

/// 256-dimensional, L2-normalized WeSpeaker ResNet34-LM embeddings.
/// Not thread-safe: callers serialize use (the app holds its MLX inference lock).
public final class WeSpeakerEmbedder {
    public static let dimension = 256
    public static let sampleRate = 16_000
    /// 0.5 s; shorter inputs give unreliable statistics.
    public static let minimumSamples = 8_000

    private let network: WeSpeakerNetwork
    private let fbank: KaldiFbank

    public init(modelDirectory: URL) throws {
        let url = modelDirectory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WeSpeakerEmbeddingError.missingWeights(url.path)
        }
        let network = WeSpeakerNetwork()
        try network.update(parameters: ModuleParameters.unflattened(MLX.loadArrays(url: url)), verify: .noUnusedKeys)
        network.train(false)
        eval(network.parameters())
        self.network = network
        fbank = KaldiFbank(options: .weSpeaker)
    }

    /// Embeds 16 kHz mono audio. Rejects short, empty or non-finite input and
    /// never returns a zero or non-finite vector.
    public func embed(_ audio: [Float]) throws -> [Float] {
        guard audio.count >= Self.minimumSamples else {
            throw WeSpeakerEmbeddingError.audioTooShort(minimumSamples: Self.minimumSamples)
        }
        guard audio.allSatisfy(\.isFinite) else { throw WeSpeakerEmbeddingError.invalidAudio }
        let features = fbank.features(audio)
        guard features.frames >= 8 else {
            throw WeSpeakerEmbeddingError.audioTooShort(minimumSamples: Self.minimumSamples)
        }
        let input = MLXArray(features.values, [1, features.frames, fbank.options.melBins, 1])
        let output = network(input)
        eval(output)
        let vector = output[0].asType(.float32).asArray(Float.self)
        Memory.clearCache()
        return try Self.validated(vector)
    }

    static func validated(_ vector: [Float]) throws -> [Float] {
        guard vector.count == dimension, vector.allSatisfy(\.isFinite) else {
            throw WeSpeakerEmbeddingError.invalidEmbedding
        }
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-6 else { throw WeSpeakerEmbeddingError.invalidEmbedding }
        return vector.map { $0 / norm }
    }
}
