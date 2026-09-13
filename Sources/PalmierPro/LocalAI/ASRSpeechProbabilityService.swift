import Foundation

#if BUNDLED_SPEECH
import MLX
import MLXAudioVAD

private enum ASRSpeechProbabilityError: Error, LocalizedError {
    case missingModel
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingModel:
            "Silero VAD MLX is not installed"
        case .invalidOutput:
            "Silero VAD MLX returned invalid speech probabilities"
        }
    }
}

actor ASRSpeechProbabilityService {
    static let shared = ASRSpeechProbabilityService()

    private var loadedModel: (revision: String, model: SileroVAD)?

    nonisolated static func chunkCount(for sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 0 }
        return ((sampleCount - 1) / ASRSpeechPreparationPolicy.standard.frameSize) + 1
    }

    func probabilities(
        samples: [Float],
        progress: @escaping @Sendable (Int, Int, String) -> Void
    ) async throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let descriptor = LocalModelManager.catalog.first(where: { $0.id == .sileroVADMLX }),
              LocalModelManager.isInstalled(descriptor) else {
            throw ASRSpeechProbabilityError.missingModel
        }

        let totalChunks = Self.chunkCount(for: samples.count)
        progress(0, totalChunks, "Checking for speech locally…")
        let model = try vadModel(for: descriptor)
        try Task.checkCancellation()
        let output = try model.predictProba(MLXArray(samples), sampleRate: ASRAudioPreprocessor.sampleRate)
        eval(output)
        try Task.checkCancellation()
        let values = output.asArray(Float.self)
        guard values.count == totalChunks, values.allSatisfy(\.isFinite) else {
            throw ASRSpeechProbabilityError.invalidOutput
        }
        progress(totalChunks, totalChunks, "Checking for speech locally… almost done")
        return values
    }

    private func vadModel(for descriptor: LocalModelDescriptor) throws -> SileroVAD {
        if let loadedModel, loadedModel.revision == descriptor.revision { return loadedModel.model }
        let directory = try LocalModelManager.directory(for: descriptor)
        let model = try SileroVAD.fromModelDirectory(directory)
        loadedModel = (descriptor.revision, model)
        return model
    }
}
#endif
