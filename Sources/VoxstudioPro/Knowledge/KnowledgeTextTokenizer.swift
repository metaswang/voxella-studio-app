import Foundation
import Tokenizers

/// Loads tokenizer files only. Indexing never loads MLX weights to choose boundaries.
actor KnowledgeTextTokenizer {
    static let shared = KnowledgeTextTokenizer()
    nonisolated static var version: String {
        let files = [SearchIndexConfig.modelID, LocalModelID.qwen3Reranker06B4Bit].map { id -> String in
            guard let folder = try? LocalModelManager.directory(for: id) else { return "bytelevel-fallback" }
            let path = folder.appendingPathComponent("tokenizer.json").path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return path + ":" + String(describing: attributes?[.size]) + ":" + String(describing: attributes?[.modificationDate])
        }
        return "token-budget-v1|" + files.joined(separator: "|")
    }
    private var tokenizers: [any Tokenizer] = []
    private var loadedVersion: String?
    private var loading: (version: String, task: Task<[any Tokenizer], Never>)?
    private var cachedChunks: [String: [KnowledgeBodyChunker.Chunk]] = [:]
    private var cacheOrder: [String] = []
    private var cachedBytes = 0

    func chunks(for body: KnowledgeTranscriptMaterial) async -> [KnowledgeBodyChunker.Chunk] {
        let version = Self.version
        let counters = await counters(for: version)
        guard !Task.isCancelled else { return [] }
        let generation = body.generation
        if loadedVersion == version, let chunks = cachedChunks[generation] { return chunks }
        // Tokenizer is Sendable. CPU work must not monopolize this actor while
        // background indexing packs a long source and foreground QA reads another.
        let work = Task.detached(priority: Task.currentPriority) {
            KnowledgeBodyChunker.pack(body) { text in
                counters.isEmpty ? KnowledgeBodyChunker.conservativeCount(text) :
                    counters.map { $0.encode(text: text, addSpecialTokens: false).count }.max()!
            }
        }
        let chunks = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        guard !Task.isCancelled else { return [] }
        guard loadedVersion == version else { return chunks }
        // Another reader may have completed the same generation while we yielded.
        if let existing = cachedChunks[generation] { return existing }
        let bytes = chunks.reduce(0) { $0 + $1.text.utf8.count + $1.context.utf8.count }
        if bytes <= 16_777_216 {
            while (cacheOrder.count >= 32 || cachedBytes + bytes > 16_777_216), let first = cacheOrder.first {
                cacheOrder.removeFirst()
                cachedBytes -= cachedChunks.removeValue(forKey: first)?.reduce(0) { $0 + $1.text.utf8.count + $1.context.utf8.count } ?? 0
            }
            cachedChunks[generation] = chunks; cacheOrder.append(generation); cachedBytes += bytes
        }
        return chunks
    }

    private func counters(for version: String) async -> [any Tokenizer] {
        if loadedVersion == version { return tokenizers }
        let task: Task<[any Tokenizer], Never>
        if let loading, loading.version == version {
            task = loading.task
        } else {
            task = Task.detached(priority: .utility) {
                var result: [any Tokenizer] = []
                for id in [SearchIndexConfig.modelID, .qwen3Reranker06B4Bit] {
                    guard let folder = try? LocalModelManager.directory(for: id),
                          FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path),
                          let tokenizer = try? await AutoTokenizer.from(modelFolder: folder) else { continue }
                    result.append(tokenizer)
                }
                return result
            }
            loading = (version, task)
        }
        let result = await task.value
        if Self.version == version, loadedVersion != version {
            tokenizers = result; loadedVersion = version
            cachedChunks = [:]; cacheOrder = []; cachedBytes = 0
        }
        if loading?.version == version { loading = nil }
        return result
    }
}
