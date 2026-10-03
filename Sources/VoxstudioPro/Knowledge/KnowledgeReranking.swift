import Foundation

struct KnowledgeRerankedHit: Sendable {
    let hit: SessionSearchHit
    let score: Double
}

enum KnowledgeRerankPolicy {
    static let primaryThreshold = 0.25
    static let relaxedThreshold = 0.175
    static let minimumEvidenceThreshold = 0.15

    static func thresholded(_ hits: [KnowledgeRerankedHit]) -> [KnowledgeRerankedHit] {
        // Scores are query dependent rankings, not calibrated evidence probabilities.
        hits.filter { $0.score.isFinite }.sorted { $0.score > $1.score }
    }
}

enum KnowledgeMMR {
    static let lambda = 0.7
    static let maximumSelections = 8

    static func select(
        _ candidates: [KnowledgeRerankedHit],
        vectors: [Int: [Float]],
        limit: Int = maximumSelections,
        coverSources: Bool = false
    ) -> [KnowledgeRerankedHit] {
        let maximum = min(max(0, limit), 32)
        guard maximum > 0 else { return [] }
        var remaining = candidates.sorted { $0.score > $1.score }
        // Reranker logits can produce very small query-dependent scores.
        // Put relevance on the same [0,1] scale as embedding similarity so
        // diversity does not overwhelm relevance solely due to score scale.
        let relevanceScale = max(1e-12, remaining.map(\.score).max() ?? 1)
        var selected: [KnowledgeRerankedHit] = []
        if coverSources {
            var seen = Set<UUID>()
            // Preserve requested source coverage among available candidates.
            // Missing sources remain gaps; candidates still need verification.
            for candidate in remaining where seen.insert(candidate.hit.sessionID).inserted {
                guard selected.count < maximum else { break }
                selected.append(candidate)
            }
            let selectedKeys = Set(selected.map { $0.hit.sessionID.uuidString + ":" + String($0.hit.unitID) })
            remaining.removeAll { selectedKeys.contains($0.hit.sessionID.uuidString + ":" + String($0.hit.unitID)) }
        }

        while !remaining.isEmpty, selected.count < maximum {
            let nextIndex = remaining.indices.max { lhs, rhs in
                mmrScore(for: remaining[lhs], selected: selected, vectors: vectors, relevanceScale: relevanceScale)
                    < mmrScore(for: remaining[rhs], selected: selected, vectors: vectors, relevanceScale: relevanceScale)
            } ?? remaining.startIndex
            selected.append(remaining.remove(at: nextIndex))
        }
        return selected
    }

    private static func mmrScore(
        for candidate: KnowledgeRerankedHit,
        selected: [KnowledgeRerankedHit],
        vectors: [Int: [Float]],
        relevanceScale: Double
    ) -> Double {
        guard !selected.isEmpty else { return candidate.score }
        let maxSimilarity = selected.map {
            similarity(candidate, $0, vectors: vectors)
        }.max() ?? 0
        return lambda * (candidate.score / relevanceScale) - (1 - lambda) * maxSimilarity
    }

    private static func similarity(
        _ lhs: KnowledgeRerankedHit,
        _ rhs: KnowledgeRerankedHit,
        vectors: [Int: [Float]]
    ) -> Double {
        if let lhsVector = vectors[lhs.hit.unitID],
           let rhsVector = vectors[rhs.hit.unitID],
           lhsVector.count == rhsVector.count,
           !lhsVector.isEmpty
        {
            return max(0, min(1, dot(lhsVector, rhsVector)))
        }
        return jaccard(lhs.hit.text, rhs.hit.text)
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + Double($1.0 * $1.1) }
    }

    private static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = terms(lhs)
        let right = terms(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(left.union(right).count)
    }

    private static func terms(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

protocol KnowledgeReranking: Sendable {
    func scores(query: String, chunks: [String]) async throws -> [Double]
}

actor RerankerService: KnowledgeReranking {
    static let shared = RerankerService()

    private init() {}

    func scores(query: String, chunks: [String]) async throws -> [Double] {
        guard !chunks.isEmpty else { return [] }
        #if BUNDLED_SPEECH
        guard LocalModelManager.isInstalled(.qwen3Reranker06B4Bit) else {
            throw LocalAIError.incompleteModel("knowledge search resources")
        }
        return try await MLXRerankerRuntime.shared.scores(query: query, chunks: chunks)
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    func releaseResidentModel() async {
        #if BUNDLED_SPEECH
        await MLXRerankerRuntime.shared.releaseResidentModel()
        #endif
    }
}

#if BUNDLED_SPEECH
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

private actor MLXRerankerRuntime {
    static let shared = MLXRerankerRuntime()

    private let prefix = "<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n"
    private let suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    private let instruction = "Given a web search query, retrieve relevant passages that answer the query"
    private var container: ModelContainer?

    func scores(query: String, chunks: [String]) async throws -> [Double] {
        try Task.checkCancellation()
        let prefix = prefix
        let suffix = suffix
        let instruction = instruction
        try await LocalSpeechScheduler.shared.beginForeignInference()
        let result: Result<[Double], Error>
        do {
            result = .success(try await scoresHoldingInference(
                query: query, chunks: chunks, prefix: prefix, suffix: suffix, instruction: instruction
            ))
        } catch {
            result = .failure(error)
        }
        await LocalSpeechScheduler.shared.endForeignInference()
        return try result.get()
    }

    private func scoresHoldingInference(
        query: String,
        chunks: [String],
        prefix: String,
        suffix: String,
        instruction: String
    ) async throws -> [Double] {
        try await MLXRuntime.beginInference()
        defer { MLXRuntime.endInference() }
        defer { MLXRuntime.releaseActivations() }
        let model = try await loaded()
        return try await model.perform(values: (query, chunks, prefix, suffix, instruction)) {
            context, input in
            let yesTokens = context.tokenizer.encode(text: "yes", addSpecialTokens: false)
            let noTokens = context.tokenizer.encode(text: "no", addSpecialTokens: false)
            guard yesTokens.count == 1, noTokens.count == 1 else {
                throw RerankerRuntimeError.missingVerdictTokens
            }
            func prompt(_ text: String) -> String {
                input.2 + "<Instruct>: \(input.4)\n<Query>: \(input.0)\n<Document>: \(text)" + input.3
            }
            guard context.tokenizer.encode(text: prompt(""), addSpecialTokens: false).count < KnowledgeBodyChunker.maximumInputTokens else {
                throw RerankerRuntimeError.inputBudgetExceeded
            }
            return try input.1.map { chunk in
                guard let body = KnowledgeTranscriptMaterial.from(transcript: .init(text: chunk, language: nil, words: [], segments: [])) else { return 0 }
                let windows = KnowledgeBodyChunker.pack(body, maximum: KnowledgeBodyChunker.maximumInputTokens) {
                    context.tokenizer.encode(text: prompt($0), addSpecialTokens: false).count
                }
                var best = 0.0
                for window in windows {
                    try Task.checkCancellation()
                    let tokens = context.tokenizer.encode(text: prompt(window.text), addSpecialTokens: false)
                    guard !tokens.isEmpty, tokens.count <= KnowledgeBodyChunker.maximumInputTokens else { throw RerankerRuntimeError.inputBudgetExceeded }
                    let logits = context.model(MLXArray(tokens)[.newAxis, .ellipsis], cache: nil)
                    let last = logits.dim(1) - 1
                    let verdict = stacked([logits[0, last, noTokens[0]], logits[0, last, yesTokens[0]]])
                    eval(verdict)
                    let values = verdict.asArray(Float.self)
                    best = max(best, 1 / (1 + exp(Double(values[0]) - Double(values[1]))))
                }
                return best
            }
        }
    }

    func releaseResidentModel() async {
        guard container != nil else { return }
        do {
            try await MLXRuntime.beginInference()
        } catch {
            return
        }
        container = nil
        MLXRuntime.releaseActivations()
        MLXRuntime.endInference()
    }

    private func loaded() async throws -> ModelContainer {
        if let container { return container }
        let directory = try LocalModelManager.directory(for: .qwen3Reranker06B4Bit)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        container = loaded
        return loaded
    }
}

private enum RerankerRuntimeError: LocalizedError {
    case missingVerdictTokens
    case emptyPrompt
    case inputBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .missingVerdictTokens: "Knowledge search resources could not be loaded."
        case .emptyPrompt: "Knowledge search could not process this request."
        case .inputBudgetExceeded: "Reranking input budget exceeded; use retrieval ordering or a shorter query."
        }
    }
}
#endif
