import Foundation
import Tokenizers
#if BUNDLED_SPEECH
import MLXAudioTTS
#endif

/// Loads only tokenizer assets. Chunk planning does not load model weights or call an LLM.
actor DubPreprocessingRuntime {
    static let shared = DubPreprocessingRuntime()
    private var cached: (key: String, tokenizer: any Tokenizer)?
    private var loading: (key: String, task: Task<any Tokenizer, Error>)?

    func prepare(_ payload: DubFlowPayload) async throws -> [LocalDubFlowRenderer.PreparedSegment] {
        let tokenizer = try await tokenizer(for: payload.model)
        try Task.checkCancellation()
        let work = Task.detached(priority: Task.currentPriority) {
            try LocalDubFlowRenderer.prepare(payload, tokenCount: { tokenizer.encode(text: $0).count })
        }
        let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        Log.app.info("Dub preprocessing \(DubChunkPlanner.version): \(result.count) chunks, installed tokenizer, 64 target-text tokens")
        for segment in result {
            let chunk = segment.planning
            Log.app.debug("Dub chunk \(segment.source.index): end=\(chunk.endUnitID), tokens=\(chunk.textTokens), estimatedSeconds=\(chunk.estimatedSeconds), forced=\(chunk.forcedBoundary), reasons=\(chunk.reasons.joined(separator: ","))")
        }
        return result
    }

    private func tokenizer(for model: DubModelChoice) async throws -> any Tokenizer {
        #if BUNDLED_SPEECH
        guard let descriptor = LocalModelManager.catalog.first(where: { $0.id == model.modelID }),
              LocalModelManager.isInstalled(descriptor) else { throw LocalAIError.missingModels(model.label) }
        #else
        throw LocalAIError.modelsUnavailable
        #endif
        let folder = try LocalModelManager.directory(for: model.modelID)
        var stamp = folder.path
        let hasFastTokenizer = FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path)
        let assets = hasFastTokenizer ? ["tokenizer.json", "tokenizer_config.json"] : ["vocab.json", "merges.txt", "tokenizer_config.json"]
        for name in assets {
            let path = folder.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                throw LocalAIError.incompleteModel(model.label)
            }
            stamp += ":\(attrs[.size] ?? 0):\(attrs[.modificationDate] ?? "")"
        }
        if let cached, cached.key == stamp { return cached.tokenizer }
        let task: Task<any Tokenizer, Error>
        if let loading, loading.key == stamp { task = loading.task }
        else {
            task = Task.detached(priority: .utility) {
                #if BUNDLED_SPEECH
                return try await Qwen3TTSModel.loadTextTokenizer(from: folder)
                #else
                throw LocalAIError.modelsUnavailable
                #endif
            }
            loading = (stamp, task)
        }
        do {
            let value = try await task.value
            if loading?.key == stamp { cached = (stamp, value); loading = nil }
            return value
        } catch {
            if loading?.key == stamp { loading = nil }
            throw error
        }
    }
}
