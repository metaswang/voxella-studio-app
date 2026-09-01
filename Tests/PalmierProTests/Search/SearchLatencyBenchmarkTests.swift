#if BUNDLED_SPEECH

import Dispatch
import Foundation
import Testing
@testable import PalmierPro

@Suite("Search latency benchmark", .serialized)
struct SearchLatencyBenchmarkTests {
    private static let queries = [
        "college applications",
        "students",
        "family",
        "颈椎",
    ]

    @Test("measures search stages")
    func measuresSearchStages() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SEARCH_LATENCY_BENCHMARK"] == "1" else {
            print("SEARCH_LATENCY_BENCHMARK_SKIPPED")
            return
        }

        let environment = ProcessInfo.processInfo.environment
        guard let databasePath = environment["SEARCH_LATENCY_DB"],
              let modelPath = environment["SEARCH_LATENCY_MODEL"] else {
            Issue.record("SEARCH_LATENCY_DB and SEARCH_LATENCY_MODEL are required")
            return
        }

        let store = try SessionIndexStore(url: URL(fileURLWithPath: databasePath))
        let provider = WeMMEmbeddingProvider()
        let hybrid = SearchService(store: store, embeddings: provider)
        let lexicalOnly = SearchService(store: store, embeddings: nil)

        let coldEmbedding = try await timed {
            try await provider.encodeText(Self.queries[0])
        }

        for query in Self.queries {
            _ = try await provider.encodeText(query)
        }

        var vectors: [[Float]] = []
        for query in Self.queries {
            vectors.append(try await provider.encodeText(query))
        }

        let warmEmbedding = try await samples(count: 20) { index in
            let query = Self.queries[index % Self.queries.count]
            return try await timed {
                try await provider.encodeText(query)
            }.milliseconds
        }

        let fts = try await samples(count: 50) { index in
            let query = Self.queries[index % Self.queries.count]
            return try await timed {
                try await store.searchLexical(
                    query: query,
                    kinds: [.sessionCard, .transcriptChunk, .mediaClip],
                    filter: .init()
                )
            }.milliseconds
        }

        let vector = try await samples(count: 50) { index in
            let queryVector = vectors[index % vectors.count]
            return try await timed {
                try await store.searchVector(
                    vector: queryVector,
                    modality: .text,
                    filter: .init()
                )
            }.milliseconds
        }

        let lexicalSearch = try await samples(count: 20) { index in
            let query = Self.queries[index % Self.queries.count]
            return try await timed {
                try await lexicalOnly.search(query: query)
            }.milliseconds
        }

        let hybridSearch = try await samples(count: 10) { index in
            let query = Self.queries[index % Self.queries.count]
            return try await timed {
                try await hybrid.search(query: query)
            }.milliseconds
        }

        print("SEARCH_LATENCY_BENCHMARK database=\(databasePath)")
        print("SEARCH_LATENCY_BENCHMARK model=\(modelPath)")
        print("SEARCH_LATENCY_BENCHMARK queries=\(Self.queries.joined(separator: " | "))")
        printMetric("embedding_cold_first_call", [coldEmbedding.milliseconds])
        printMetric("embedding_warm_encode_text", warmEmbedding)
        printMetric("sqlite_fts_search_lexical", fts)
        printMetric("sqlite_vec_search_text", vector)
        printMetric("search_lexical_only", lexicalSearch)
        printMetric("search_end_to_end_hybrid", hybridSearch)
    }

    private struct Timed<Value> {
        let value: Value
        let milliseconds: Double
    }

    private func timed<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Timed<Value> {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Timed(
            value: value,
            milliseconds: Double(end - start) / 1_000_000
        )
    }

    private func samples(
        count: Int,
        _ operation: (Int) async throws -> Double
    ) async throws -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(try await operation(index))
        }
        return values
    }

    private func printMetric(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let p50 = percentile(sorted, fraction: 0.50)
        let p95 = percentile(sorted, fraction: 0.95)
        let mean = values.reduce(0, +) / Double(values.count)
        print(
            String(
                format: "SEARCH_LATENCY_METRIC name=%@ n=%d min_ms=%.3f mean_ms=%.3f p50_ms=%.3f p95_ms=%.3f max_ms=%.3f",
                name,
                values.count,
                sorted.first ?? .nan,
                mean,
                p50,
                p95,
                sorted.last ?? .nan
            )
        )
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let index = min(
            sorted.count - 1,
            max(0, Int(ceil(fraction * Double(sorted.count))) - 1)
        )
        return sorted[index]
    }
}

#endif
