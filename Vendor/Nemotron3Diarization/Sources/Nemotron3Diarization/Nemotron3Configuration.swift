import Foundation

public enum Nemotron3DiarizationError: LocalizedError, Equatable {
    case missingArtifact(String)
    case invalidConfiguration(String)
    case incompatibleWeights(String)
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .missingArtifact(let path):
            "Nemotron 3 local artifact is missing: \(path)"
        case .invalidConfiguration(let reason):
            "Invalid Nemotron 3 artifact configuration: \(reason)"
        case .incompatibleWeights(let reason):
            "Incompatible Nemotron 3 weights: \(reason)"
        case .runtime(let reason):
            "Nemotron 3 inference failed: \(reason)"
        }
    }
}

/// Offline geometry of the pinned Nemotron 3 export. The cache runs at 80 ms
/// encoder rows; speaker activity is emitted every 10 ms.
public struct Nemotron3Geometry: Equatable, Sendable {
    public var sampleRate = 16_000
    public var windowLength = 400
    public var fftLength = 512
    public var hopLength = 160
    public var melBins = 128
    public var preemphasis: Float = 0.97
    public var modelDimension = 512
    public var speakerCount = 8
    public var subsamplingFactor = 8
    /// Confirmed encoder rows per call (27.2 s).
    public var chunkLength = 340
    /// Look-ahead encoder rows per call (3.2 s).
    public var rightContext = 40
    public var speakerCacheLength = 264
    public var fifoLength = 40
    public var speakerCacheUpdatePeriod = 300
    public var silenceFramesPerSpeaker = 1
    /// Cache-selection floor only; it is not the activity threshold.
    public var predictionScoreThreshold: Float = 0.25
    public var latestFramesScoreBoost: Float = 0.05
    public var strongBoostRate: Float = 0.75
    public var weakBoostRate: Float = 1.5
    public var minPositiveScoresRate: Float = 0.5

    public static let offline = Nemotron3Geometry()

    public init() {}

    /// Seconds represented by one emitted probability row.
    public var frameDuration: Double { Double(hopLength) / Double(sampleRate) }
    public var chunkMelFrames: Int { chunkLength * subsamplingFactor }
    public var rightContextMelFrames: Int { rightContext * subsamplingFactor }
    public var fixedChunkMelFrames: Int { chunkMelFrames + rightContextMelFrames }
    public var packedCapacity: Int { speakerCacheLength + fifoLength + chunkLength + rightContext }
    public var chunkDuration: Double { Double(chunkMelFrames) * frameDuration }
    public var rightContextDuration: Double { Double(rightContextMelFrames) * frameDuration }

    /// Valid 10 ms frames for `sampleCount` samples. Matches the reference
    /// extractor's attention mask, which drops the final centered frame.
    public func frameCount(sampleCount: Int) -> Int {
        max(0, sampleCount) / hopLength
    }

    public func chunkCount(sampleCount: Int) -> Int {
        let frames = frameCount(sampleCount: sampleCount)
        return frames == 0 ? 0 : (frames + chunkMelFrames - 1) / chunkMelFrames
    }
}

public struct Nemotron3ArtifactConfiguration: Decodable, Sendable {
    public struct Quantization: Decodable, Sendable {
        public let groupSize: Int?
        public let bits: Int?
        public let mode: String?
    }

    public static let sourceModel = "nvidia/Nemotron-3-Diarization"
    public static let sourceRevision = "a435e9867d79e789e90053f9b6d6834053af564a"

    public let modelType: String
    public let sourceModel: String
    public let sourceRevision: String
    public let dtype: String
    public let sampleRate: Int
    public let nMels: Int
    public let dModel: Int
    public let tfModel: Int
    public let numLayers: Int
    public let numHeads: Int
    public let numSpeakers: Int
    public let subsamplingFactor: Int
    public let upsampleFactor: Int
    public let spkcacheLen: Int
    public let fifoLen: Int
    public let chunkLen: Int
    public let rightContext: Int
    public let spkcacheUpdatePeriod: Int
    public let quantization: Quantization

    public static func load(from directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Nemotron3DiarizationError.missingArtifact(url.path)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(Self.self, from: Data(contentsOf: url))
        try configuration.validate(against: .offline)
        return configuration
    }

    func validate(against geometry: Nemotron3Geometry) throws {
        guard modelType == "nemotron3_diarization",
              sourceModel == Self.sourceModel,
              sourceRevision == Self.sourceRevision else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "bundle must use the pinned final Nemotron 3 checkpoint")
        }
        guard dtype == "int8" else {
            throw Nemotron3DiarizationError.invalidConfiguration("only the INT8 export is supported")
        }
        guard quantization.groupSize == 64, quantization.bits == 8, quantization.mode == "affine" else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "MLX runtime requires affine group-64 INT8 weights")
        }
        guard sampleRate == geometry.sampleRate, nMels == geometry.melBins,
              dModel == geometry.modelDimension, tfModel == 192, numLayers == 31, numHeads == 8,
              numSpeakers == geometry.speakerCount, subsamplingFactor == geometry.subsamplingFactor,
              upsampleFactor == geometry.subsamplingFactor, spkcacheLen == geometry.speakerCacheLength,
              fifoLen == geometry.fifoLength, chunkLen == geometry.chunkLength,
              rightContext == geometry.rightContext,
              spkcacheUpdatePeriod == geometry.speakerCacheUpdatePeriod else {
            throw Nemotron3DiarizationError.invalidConfiguration(
                "artifact geometry does not match the supported offline graph")
        }
    }
}
