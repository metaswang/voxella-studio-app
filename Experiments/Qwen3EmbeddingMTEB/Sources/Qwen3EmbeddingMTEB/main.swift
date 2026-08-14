import Foundation
import Darwin
import Accelerate
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

private let modelID = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
private let dimensions = [1024, 512, 256]

private struct Suite: Decodable {
    let seed: Int
}

private struct Query: Codable {
    let id: String
    let text: String
}

private struct Document: Codable {
    let id: String
    let text: String
}

private struct RetrievalDataset: Decodable {
    let name: String
    let category: String
    let instruction: String
    let queryLanguage: String
    let documentLanguage: String
    let queries: [Query]
    let documents: [Document]
    let qrels: [String: [String: Int]]

    enum CodingKeys: String, CodingKey {
        case name, category, instruction, queries, documents, qrels
        case queryLanguage = "query_language"
        case documentLanguage = "document_language"
    }
}

private struct EncodingStatistics: Codable {
    let inputs: Int
    let averageTokens: Double
    let maximumTokens: Int
    let truncatedInputs: Int
    let seconds: Double
}

private struct RetrievalMetrics: Codable {
    let ndcgAt10: Double
    let recallAt10: Double
    let mrrAt10: Double

    enum CodingKeys: String, CodingKey {
        case ndcgAt10 = "ndcg@10"
        case recallAt10 = "recall@10"
        case mrrAt10 = "mrr@10"
    }
}

private struct DimensionResult: Codable {
    let metrics: RetrievalMetrics
    let vectorBytesPerItem: Int
}

private struct DatasetResult: Codable {
    let name: String
    let category: String
    let queryLanguage: String
    let documentLanguage: String
    let queries: Int
    let documents: Int
    let queryEncoding: EncodingStatistics
    let documentEncoding: EncodingStatistics
    let dimensions: [String: DimensionResult]

    enum CodingKeys: String, CodingKey {
        case name, category, queries, documents, dimensions
        case queryLanguage = "query_language"
        case documentLanguage = "document_language"
        case queryEncoding = "query_encoding"
        case documentEncoding = "document_encoding"
    }
}

private struct ExperimentResult: Codable {
    let model: String
    let implementation: String
    let generatedAt: String
    let maximumTokens: Int
    let batchSize: Int
    let matryoshka: String
    let datasets: [DatasetResult]

    enum CodingKeys: String, CodingKey {
        case model, implementation, datasets
        case generatedAt = "generated_at"
        case maximumTokens = "maximum_tokens"
        case batchSize = "batch_size"
        case matryoshka
    }
}

private struct Arguments {
    let suiteDirectory: URL
    let outputURL: URL
    let maximumTokens: Int
    let batchSize: Int

    init() throws {
        let values = Array(CommandLine.arguments.dropFirst())
        guard values.count >= 2 else {
            throw ExperimentError.usage
        }
        suiteDirectory = URL(filePath: values[0], directoryHint: .isDirectory)
        outputURL = URL(filePath: values[1])
        maximumTokens = Self.value(named: "--max-tokens", in: values) ?? 2_048
        batchSize = Self.value(named: "--batch-size", in: values) ?? 8
        guard maximumTokens > 0, batchSize > 0 else {
            throw ExperimentError.invalidArguments
        }
    }

    private static func value(named name: String, in values: [String]) -> Int? {
        guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else {
            return nil
        }
        return Int(values[index + 1])
    }
}

private enum ExperimentError: LocalizedError {
    case usage
    case invalidArguments
    case invalidEmbeddingDimension(Int)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: Qwen3EmbeddingMTEB <suite-directory> <results.json> [--max-tokens N] [--batch-size N]"
        case .invalidArguments:
            return "--max-tokens and --batch-size must be positive integers."
        case let .invalidEmbeddingDimension(dimension):
            return "Expected a 1024-d embedding, received \(dimension) dimensions."
        }
    }
}

private final class Embedder {
    private let container: EmbedderModelContainer
    private let maximumTokens: Int
    private let batchSize: Int

    init(maximumTokens: Int, batchSize: Int) async throws {
        self.maximumTokens = maximumTokens
        self.batchSize = batchSize
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: .init(id: modelID)
        )
    }

    func encode(_ texts: [String]) async throws -> (vectors: [[Float]], statistics: EncodingStatistics) {
        let started = ContinuousClock.now
        var vectors: [[Float]] = []
        var originalTokenCount = 0
        var maximumTokenCount = 0
        var truncatedInputs = 0
        let maximumTokens = maximumTokens

        for texts in texts.chunks(ofCount: batchSize) {
            let result = await container.perform(nonSendable: texts) { context, batch in
                let encoded = batch.map {
                    context.tokenizer.encode(text: $0, addSpecialTokens: true)
                }
                let tokenCounts = encoded.map(\.count)
                let capped = encoded.map { Array($0.prefix(maximumTokens)) }
                let paddingToken = context.tokenizer.eosTokenId ?? 0
                let maximumLength = capped.map(\.count).max() ?? 1
                let padded = stacked(capped.map { tokens in
                    MLXArray(tokens + Array(repeating: paddingToken, count: maximumLength - tokens.count))
                })
                let mask = padded .!= MLXArray(paddingToken)
                let tokenTypes = MLXArray.zeros(like: padded)
                let output = context.model(
                    padded,
                    positionIds: nil,
                    tokenTypeIds: tokenTypes,
                    attentionMask: mask
                )
                let pooled = context.pooling(output, mask: mask, normalize: true)
                eval(pooled)
                return (
                    pooled.map { $0.asArray(Float.self) },
                    tokenCounts,
                    capped.map(\.count)
                )
            }
            for vector in result.0 {
                guard vector.count == 1024 else {
                    throw ExperimentError.invalidEmbeddingDimension(vector.count)
                }
                vectors.append(vector)
            }
            originalTokenCount += result.1.reduce(0, +)
            maximumTokenCount = max(maximumTokenCount, result.1.max() ?? 0)
            truncatedInputs += zip(result.1, result.2).filter { $0.0 > $0.1 }.count
        }

        let duration = started.duration(to: .now).components
        return (
            vectors,
            .init(
                inputs: texts.count,
                averageTokens: texts.isEmpty ? 0 : Double(originalTokenCount) / Double(texts.count),
                maximumTokens: maximumTokenCount,
                truncatedInputs: truncatedInputs,
                seconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            )
        )
    }
}

private extension Array {
    func chunks(ofCount size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}

private func prefixNormalized(_ vector: [Float], dimension: Int) -> [Float] {
    precondition(vector.count == 1024)
    let prefix = vector.prefix(dimension)
    let norm = sqrt(prefix.reduce(Float.zero) { $0 + $1 * $1 })
    guard norm > 0 else { return Array(repeating: 0, count: dimension) }
    return prefix.map { $0 / norm }
}

private func metrics(
    queryVectors: [[Float]],
    documentVectors: [[Float]],
    queryIDs: [String],
    documentIDs: [String],
    qrels: [String: [String: Int]]
) -> RetrievalMetrics {
    let queryCount = queryVectors.count
    let documentCount = documentVectors.count
    let dimension = queryVectors.first?.count ?? 0
    precondition(
        dimension > 0
            && queryVectors.allSatisfy { $0.count == dimension }
            && documentVectors.allSatisfy { $0.count == dimension }
    )
    let flattenedQueries = queryVectors.flatMap { $0 }
    let flattenedDocuments = documentVectors.flatMap { $0 }
    var similarities = Array(repeating: Float.zero, count: queryCount * documentCount)
    flattenedQueries.withUnsafeBufferPointer { queryBuffer in
        flattenedDocuments.withUnsafeBufferPointer { documentBuffer in
            similarities.withUnsafeMutableBufferPointer { similarityBuffer in
                cblas_sgemm(
                    CblasRowMajor,
                    CblasNoTrans,
                    CblasTrans,
                    Int32(queryCount),
                    Int32(documentCount),
                    Int32(dimension),
                    1,
                    queryBuffer.baseAddress,
                    Int32(dimension),
                    documentBuffer.baseAddress,
                    Int32(dimension),
                    0,
                    similarityBuffer.baseAddress,
                    Int32(documentCount)
                )
            }
        }
    }
    var ndcg = 0.0
    var recall = 0.0
    var reciprocalRank = 0.0

    for queryIndex in queryVectors.indices {
        let scoreOffset = queryIndex * documentCount
        let top10 = (0 ..< documentCount).sorted {
            similarities[scoreOffset + $0] > similarities[scoreOffset + $1]
        }.prefix(10)
        let judgments = qrels[queryIDs[queryIndex]] ?? [:]
        let relevant = judgments.filter { $0.value > 0 }
        let retrieved = top10.compactMap { judgments[documentIDs[$0]] }.filter { $0 > 0 }
        recall += relevant.isEmpty ? 0 : Double(retrieved.count) / Double(relevant.count)

        let actualDCG = top10.enumerated().reduce(0.0) { total, entry in
            let relevance = Double(judgments[documentIDs[entry.element]] ?? 0)
            return total + (pow(2, relevance) - 1) / log2(Double(entry.offset + 2))
        }
        let idealDCG = relevant.values.sorted(by: >).prefix(10).enumerated().reduce(0.0) { total, entry in
            total + (pow(2, Double(entry.element)) - 1) / log2(Double(entry.offset + 2))
        }
        ndcg += idealDCG == 0 ? 0 : actualDCG / idealDCG
        if let first = top10.firstIndex(where: { judgments[documentIDs[$0], default: 0] > 0 }) {
            reciprocalRank += 1 / Double(first + 1)
        }
    }

    let count = Double(queryVectors.count)
    return .init(ndcgAt10: ndcg / count, recallAt10: recall / count, mrrAt10: reciprocalRank / count)
}

private func run(dataset: RetrievalDataset, embedder: Embedder) async throws -> DatasetResult {
    print("Encoding \(dataset.name): \(dataset.queries.count) queries, \(dataset.documents.count) documents")
    let queryTexts = dataset.queries.map { "Instruct: \(dataset.instruction)\nQuery: \($0.text)" }
    let queryResult = try await embedder.encode(queryTexts)
    let documentResult = try await embedder.encode(dataset.documents.map(\.text))
    let queryIDs = dataset.queries.map(\.id)
    let documentIDs = dataset.documents.map(\.id)
    var results: [String: DimensionResult] = [:]
    for dimension in dimensions {
        let metric = metrics(
            queryVectors: queryResult.vectors.map { prefixNormalized($0, dimension: dimension) },
            documentVectors: documentResult.vectors.map { prefixNormalized($0, dimension: dimension) },
            queryIDs: queryIDs,
            documentIDs: documentIDs,
            qrels: dataset.qrels
        )
        results[String(dimension)] = .init(metrics: metric, vectorBytesPerItem: dimension * MemoryLayout<Float>.size)
    }
    return .init(
        name: dataset.name,
        category: dataset.category,
        queryLanguage: dataset.queryLanguage,
        documentLanguage: dataset.documentLanguage,
        queries: dataset.queries.count,
        documents: dataset.documents.count,
        queryEncoding: queryResult.statistics,
        documentEncoding: documentResult.statistics,
        dimensions: results
    )
}

@main
private enum Main {
    static func main() async {
        do {
            let arguments = try Arguments()
            let data = try Data(contentsOf: arguments.suiteDirectory.appending(component: "manifest.json"))
            _ = try JSONDecoder().decode(Suite.self, from: data)
            let filenames = try FileManager.default.contentsOfDirectory(
                at: arguments.suiteDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let decoder = JSONDecoder()
            let datasets = try filenames.map { try decoder.decode(RetrievalDataset.self, from: Data(contentsOf: $0)) }
            let embedder = try await Embedder(maximumTokens: arguments.maximumTokens, batchSize: arguments.batchSize)
            var results: [DatasetResult] = []
            for dataset in datasets {
                try Task.checkCancellation()
                results.append(try await run(dataset: dataset, embedder: embedder))
            }
            let output = ExperimentResult(
                model: modelID,
                implementation: "Apple MLX Swift LM 3.31.4 / MLXEmbedders",
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                maximumTokens: arguments.maximumTokens,
                batchSize: arguments.batchSize,
                matryoshka: "e1024 = L2-normalized pooled embedding; e512/e256 = L2-normalize(e1024[0..<d])",
                datasets: results
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(output).write(to: arguments.outputURL, options: .atomic)
            print("Wrote \(arguments.outputURL.path)")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
