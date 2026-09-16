import Foundation

#if BUNDLED_SPEECH
@preconcurrency import CoreML
import FluidAudio
#endif

enum LocalSpeechVADBackend: String, Codable, Equatable, Hashable, Sendable {
    case coreML = "coreml"
}

struct SpeechRegion: Codable, Equatable, Sendable {
    let startTime: Float
    let endTime: Float
}

struct SpeechRegionAnalysis: Codable, Equatable, Sendable {
    let sampleRate: Int
    let chunkCount: Int
    let probabilities: [Float]
    let segments: [SpeechRegion]
    let backend: LocalSpeechVADBackend
    let modelRevision: String
}

enum LocalSpeechVAD {
    static let sampleRate = 16_000
    static let chunkSize = 4096
    static let coreMLBundleName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    static let requiredBundleFiles = [
        "model.mil",
        "metadata.json",
        "coremldata.bin",
        "weights/weight.bin",
    ]

    static func chunkCount(for sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        return ((sampleCount - 1) / chunkSize) + 1
    }
}

#if BUNDLED_SPEECH
private enum LocalSpeechVADError: Error, LocalizedError {
    case missingModel
    case missingCoreMLBundle(URL)

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Silero VAD is not installed"
        case .missingCoreMLBundle(let url):
            return "Silero VAD Core ML bundle is missing at \(url.path)"
        }
    }
}

actor SpeechAnalysisService {
    static let shared = SpeechAnalysisService()

    private struct ModelKey: Hashable, Sendable {
        let revision: String
        let threshold: Float
    }

    private var managers: [ModelKey: VadManager] = [:]

    func probabilities(
        samples: [Float],
        threshold: Float = 0.5,
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> [Float] {
        try await analyze(samples: samples, threshold: threshold, progress: progress).probabilities
    }

    func analyze(
        samples: [Float],
        threshold: Float = 0.5,
        segmentation: VadSegmentationConfig? = nil,
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> SpeechRegionAnalysis {
        guard !samples.isEmpty else {
            return SpeechRegionAnalysis(
                sampleRate: LocalSpeechVAD.sampleRate,
                chunkCount: 0,
                probabilities: [],
                segments: [],
                backend: .coreML,
                modelRevision: "none"
            )
        }

        guard let descriptor = LocalModelManager.catalog.first(where: { $0.id == .sileroVAD }),
              LocalModelManager.isInstalled(descriptor) else {
            throw LocalSpeechVADError.missingModel
        }

        let totalChunks = LocalSpeechVAD.chunkCount(for: samples.count)
        progress(0, totalChunks, "Checking for speech locally…")
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let manager = try await vadManager(for: descriptor, threshold: threshold)
        try Task.checkCancellation()
        var segmentationConfig = segmentation ?? .default
        segmentationConfig.maxSpeechDuration = .infinity
        let results = try await manager.process(samples)
        try Task.checkCancellation()
        let segments = await manager.segmentSpeech(
            from: results,
            totalSamples: samples.count,
            config: segmentationConfig
        )
        progress(totalChunks, totalChunks, "Checking for speech locally… almost done")

        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        let analysis = SpeechRegionAnalysis(
            sampleRate: LocalSpeechVAD.sampleRate,
            chunkCount: totalChunks,
            probabilities: results.map(\.probability),
            segments: segments.map {
                SpeechRegion(startTime: Float($0.startTime), endTime: Float($0.endTime))
            },
            backend: .coreML,
            modelRevision: descriptor.revision
        )
        let audioSeconds = Double(samples.count) / Double(LocalSpeechVAD.sampleRate)
        Log.transcription.notice(
            "VAD completed backend=\(LocalSpeechVADBackend.coreML.rawValue) chunks=\(analysis.chunkCount) "
                + "segments=\(analysis.segments.count) elapsed=\(String(format: "%.4f", elapsed))s "
                + "rtf=\(String(format: "%.5f", elapsed / max(0.001, audioSeconds)))"
        )
        return analysis
    }

    private func vadManager(
        for descriptor: LocalModelDescriptor,
        threshold: Float
    ) async throws -> VadManager {
        let key = ModelKey(revision: descriptor.revision, threshold: threshold)
        if let manager = managers[key] { return manager }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let directory = try LocalModelManager.directory(for: descriptor)
        let modelURL = directory.appendingPathComponent(LocalSpeechVAD.coreMLBundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalSpeechVADError.missingCoreMLBundle(modelURL)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        let config = VadConfig(
            defaultThreshold: threshold,
            computeUnits: .cpuOnly
        )
        let manager = VadManager(config: config, vadModel: model)
        managers[key] = manager
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        Log.transcription.notice(
            "VAD model ready backend=\(LocalSpeechVADBackend.coreML.rawValue) revision=\(descriptor.revision) "
                + "elapsed=\(String(format: "%.2f", elapsed))s"
        )
        return manager
    }
}
#endif
