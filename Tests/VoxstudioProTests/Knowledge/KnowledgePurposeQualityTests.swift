import Foundation
import MCP
import Testing
@testable import VoxstudioPro

/// Model-reviewed reference answers and source spans are checked independently
/// of retrieval. These tests measure evidence plumbing, not answer-model quality.
@Suite("Knowledge purpose QA corpus", .serialized)
struct KnowledgePurposeQualityTests {
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Knowledge/purpose-qa-v1")
    private struct Corpus: Decodable {
        var ownerId: String
        var sources: [Source]
        struct Source: Decodable {
            var key: String; var id: String; var title: String; var text: String
            var kind: String; var origin: String; var video: Bool
            var summary: String?; var subtitle: String?; var translation: String?
            var mediaDuration: Double?; var created: String; var modified: String
            var segments: [Segment]
        }
        struct Segment: Decodable { var text: String; var start: Double; var end: Double; var speaker: String? }
    }
    private struct Gold: Decodable {
        var caseId: String; var category: String; var question: String; var focus: [String]
        var referenceAnswer: String; var annotationOrigin: String; var evidence: [Evidence]
        struct Evidence: Decodable {
            var source: String; var material: String; var quote: String
            var characterStart: Int; var characterEnd: Int
        }
    }
    private func load() throws -> (Corpus, [Gold]) {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(Corpus.self, from: Data(contentsOf: Self.directory.appendingPathComponent("corpus.json")))
        let gold = try String(contentsOf: Self.directory.appendingPathComponent("gold.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try decoder.decode(Gold.self, from: Data($0.utf8)) }
        return (corpus, gold)
    }
    @MainActor private func sources(_ corpus: Corpus) throws -> [WorkbenchSession] {
        try corpus.sources.map { item in
            var source = KnowledgeEvidenceWorkspaceTests().fixture(title: item.title, duration: item.mediaDuration, summary: item.summary)
            source.id = try #require(UUID(uuidString: item.id))
            source.sourceURL = URL(fileURLWithPath: "/private/tmp/purpose-qa-fixture-\(item.key).\(item.video ? "mp4" : "m4a")")
            source.transcript = item.text.isEmpty ? nil : .init(text: item.text, language: item.key == "textonly" ? "en" : "zh", words: [],
                segments: item.segments.map { .init(text: $0.text, start: $0.start, end: $0.end, speaker: $0.speaker) })
            source.sessionType = item.kind == "dub" ? .dub : item.kind == "meeting" ? .meetingRecord : .upload
            source.source = item.kind == "dub" ? .standaloneDub : .media
            source.storage = item.origin == "cloud" ? .cloud : .local
            source.remoteSessionID = item.origin == "cloud" ? source.id : nil
            source.remoteSourceHasVideo = item.video
            source.createdAt = try #require(ISO8601DateFormatter().date(from: item.created))
            source.modifiedAt = try #require(ISO8601DateFormatter().date(from: item.modified))
            if let text = item.subtitle {
                source.subtitleTrack = .init(sourceLanguage: "zh", language: "zh", cues: [.init(id: 0, sourceIDs: [], text: text, start: 1, end: 20, speaker: nil)])
            }
            if let text = item.translation {
                source.translationTracks = [.init(languageCode: "en", track: .init(sourceLanguage: "zh", language: "en", cues: [.init(id: 0, sourceIDs: [], text: text, start: 1420, end: 1440, speaker: "张三")]))]
            }
            return source
        }
    }
    @MainActor private func scope(_ corpus: Corpus, _ sources: [WorkbenchSession]) -> KnowledgeScopeSnapshot {
        .init(scope: .all, ownerID: UUID(uuidString: corpus.ownerId), sessions: sources,
              generations: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, KnowledgeScopeSnapshot.generation($0)) }), isLive: false)
    }
    private func payload(_ result: CallTool.Result) throws -> [String: Any] {
        #expect(result.isError != true)
        guard case let .text(text, _, _) = result.content.first else { throw KnowledgeQAError.invalidRerankerOutput }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test @MainActor func sixtyReferenceAnswersBindToCurrentReadableMaterialAndAuthorizedCatalog() async throws {
        SessionIndexCoordinator.shared.pauseIndexing()
        let (corpus, gold) = try load(), sessions = try sources(corpus), snapshot = scope(corpus, sessions)
        #expect(gold.count == 60 && Set(gold.map(\.caseId)).count == 60)
        #expect(gold.allSatisfy { !$0.referenceAnswer.isEmpty && $0.annotationOrigin == "model_assisted_source_review" })
        var currentText: [String: String] = [:]
        for (item, source) in zip(corpus.sources, sessions) {
            let read = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch", args: ["source_id": source.id.uuidString, "limit": 100], snapshot: snapshot))
            let text = (read["segments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            if let body = KnowledgeTranscriptMaterial.from(source) { #expect(text == body.text) }
            else { #expect(read["status"] as? String == "unavailable") }
            currentText[item.key] = text
            if item.translation != nil {
                let translated = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch", args: ["source_id": source.id.uuidString, "material": "translation", "language": "en"], snapshot: snapshot))
                currentText[item.key + ":translation"] = (translated["segments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            }
        }
        for row in gold {
            #expect(row.focus.allSatisfy { currentText[$0] != nil })
            for evidence in row.evidence {
                let key = evidence.source + (evidence.material == "translation" ? ":translation" : "")
                let text = try #require(currentText[key]) as NSString
                #expect(evidence.characterStart >= 0 && evidence.characterEnd <= text.length)
                #expect(text.substring(with: NSRange(location: evidence.characterStart, length: evidence.characterEnd - evidence.characterStart)) == evidence.quote)
                let find = try payload(await MCPKnowledgeBaseTools.execute(name: "find_text", args: ["text": evidence.quote,
                    "source_id": try #require(corpus.sources.first { $0.key == evidence.source }?.id),
                    "material": evidence.material == "translation" ? "translation" : "canonical", "language": evidence.material == "translation" ? "en" : "zh"], snapshot: snapshot))
                #expect(find["occurrence_count"] as? Int == 1)
            }
        }
        let catalog = try payload(await MCPKnowledgeBaseTools.execute(name: "list_sources", args: [:], snapshot: snapshot))
        #expect(catalog["total_count"] as? Int == 9)
        let aggregate = try payload(await MCPKnowledgeBaseTools.execute(name: "aggregate", args: [:], snapshot: snapshot))
        let values = try #require(aggregate["aggregate"] as? [String: Any])
        #expect(values["count"] as? Int == 9)
        #expect(values["media_duration_sum_sec"] as? Double == 11_122)
        #expect(values["duration_unknown_count"] as? Int == 2)
    }

    #if BUNDLED_SPEECH
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_KNOWLEDGE_PURPOSE_EVAL"] == "1"))
    @MainActor func realWeMMAndRerankerCompareNativeB0AndKnowledgeMCPRetrieval() async throws {
        // Live Workbench initialization may reconcile its index. This benchmark
        // owns a temporary store and must not compete with that background work.
        SessionIndexCoordinator.shared.pauseIndexing()
        let (corpus, gold) = try load(), sessions = try sources(corpus), snapshot = scope(corpus, sessions)
        try #require(LocalModelManager.isInstalled(SearchIndexConfig.modelID))
        try #require(LocalModelManager.isInstalled(.qwen3Reranker06B4Bit))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-purpose-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionIndexStore(url: directory.appendingPathComponent("index.sqlite"))
        var referenceUnits: [String: [KnowledgeBodyChunker.Chunk]] = [:]
        for source in sessions {
            print("[purpose-eval] indexing \(source.id.uuidString)")
            var index = try #require(SessionIndexSnapshot.from(session: source, sourceOrigin: KnowledgeScopeSnapshot.origin(source), ownerUserID: corpus.ownerId))
            if let body = index.selectedBody {
                index.preparedChunks = await KnowledgeTextTokenizer.shared.chunks(for: body)
                referenceUnits[source.id.uuidString] = index.preparedChunks
            }
            try await store.replaceLexical(snapshot: index, clips: CuePacker.pack(cues: index.cues))
            for unit in try await store.unitsNeedingEmbedding(sessionID: source.id) where !unit.text.isEmpty {
                let vector = try await WeMMEmbeddingProvider.shared.encodeText(unit.text)
                try await store.upsertEmbedding(unitID: unit.id, modality: .text, vector: vector)
            }
        }
        let search = SearchService(store: store, embeddings: WeMMEmbeddingProvider.shared)
        let generations = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in KnowledgeTranscriptMaterial.from(s).map { (s.id, $0.generation) } })
        let owner = corpus.ownerId
        let retrieval = KnowledgeRetrievalService(dependencies: .init(hybridRecall: { query, supplied in
            var filter = supplied
            filter.sourceOrigins = [.local, .cloud]; filter.cloudOwnerUserID = owner; filter.canonicalGenerations = generations
            return try await search.transcriptSearch(query: query, filter: filter)
        }, reranker: { query, texts in try await RerankerService.shared.scores(query: query, chunks: texts) },
           textEmbeddings: { ids in try await store.textEmbeddings(unitIDs: ids) }))
        var results: [[String: Any]] = []
        let englishNote = try #require(corpus.sources.first { $0.key == "textonly" })
        let releaseNote = try #require(corpus.sources.first { $0.key == "A" })
        func probe(_ id: String, _ question: String, _ source: Corpus.Source, _ quote: String) -> Gold {
            let range = (source.text as NSString).range(of: quote)
            return .init(caseId: id, category: "language_probe", question: question, focus: [source.key],
                referenceAnswer: quote, annotationOrigin: "model_assisted_source_review",
                evidence: [.init(source: source.key, material: "canonical", quote: quote,
                    characterStart: range.location, characterEnd: range.location + range.length)])
        }
        let probes = [
            probe("english-product", "What must happen before VoxStudio 2.4 releases?", englishNote, "VoxStudio 2.4 releases after review."),
            probe("cross-language-product", "哪个产品版本将在审查后发布？", englishNote, "VoxStudio 2.4 releases after review."),
            probe("cross-language-release", "What was the final decision about the release date and its condition?", releaseNote, "最终确认延期到下周二，条件是安全测试全部通过。")
        ]
        for row in gold + probes {
            let ids = corpus.sources.filter { row.focus.contains($0.key) }.compactMap { UUID(uuidString: $0.id) }
            let expected = row.evidence.filter { $0.material == "canonical" }
            guard !expected.isEmpty else { continue }
            print("[purpose-eval] retrieving \(row.caseId)")
            for (variant, path) in [("native_retrieval", KnowledgeRetrievalPath.agent), ("b0_retrieval", .legacy)] {
                let started = ContinuousClock.now
                let result = try await retrieval.search(.init(query: row.question, scope: .sessions(ids), originFilter: nil,
                    resultLimit: 8, requestID: UUID(), includeCatalog: false, retrievalPath: path, useGraph: false))
                let rows = result.hits.map { ["source_id": $0.sessionID.uuidString, "character_start": $0.characterStart as Any? ?? NSNull(),
                    "character_end": $0.characterEnd as Any? ?? NSNull(), "text": $0.text] }
                results.append(metric(row, hits: rows, corpus: corpus, referenceUnits: referenceUnits, variant: variant, elapsed: started.duration(to: .now), reranker: result.diagnostics.rerankerStatus.rawValue))
            }
            let started = ContinuousClock.now
            let result = try payload(await MCPKnowledgeBaseTools.execute(name: "search", args: ["query": row.question,
                "source_ids": ids.map(\.uuidString), "rerank": "auto", "limit": 8], snapshot: snapshot, service: search))
            results.append(metric(row, hits: result["results"] as? [[String: Any]] ?? [], corpus: corpus, referenceUnits: referenceUnits, variant: "knowledge_mcp",
                elapsed: started.duration(to: .now), reranker: (result["retrieval"] as? [String: Any])?["reranker"] as? String ?? "unknown"))
        }
        let report: [String: Any] = ["corpus": "purpose-qa-v1", "annotation_origin": "model_assisted_source_review", "gold_cases": gold.count,
            "answer_model_metrics_measured": false, "method_ablations_measured": false, "media_metrics_measured": false,
            "language_probe_cases": probes.count,
            "embedding_model": SearchIndexConfig.visualSpec.model, "embedding_dimension": 256, "result_limit": 8,
            "rerank_budget_seconds": 5, "results": results]
        let path = ProcessInfo.processInfo.environment["KNOWLEDGE_PURPOSE_EVAL_OUTPUT"] ?? "/private/tmp/voxstudio-purpose-qa-eval.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        #expect(results.count == (gold.filter { $0.evidence.contains { $0.material == "canonical" } }.count + probes.count) * 3)
    }

    private func metric(_ row: Gold, hits: [[String: Any]], corpus: Corpus, referenceUnits: [String: [KnowledgeBodyChunker.Chunk]], variant: String, elapsed: Duration, reranker: String) -> [String: Any] {
        let expected = row.evidence.filter { $0.material == "canonical" }
        func matches(_ hit: [String: Any], _ evidence: Gold.Evidence) -> Bool {
            hit["source_id"] as? String == corpus.sources.first { $0.key == evidence.source }?.id &&
                (hit["character_start"] as? Int ?? Int.max) < evidence.characterEnd &&
                (hit["character_end"] as? Int ?? Int.min) > evidence.characterStart
        }
        let recalled = expected.filter { evidence in hits.contains { matches($0, evidence) } }.count
        let grades = hits.map { hit in expected.contains { matches(hit, $0) } ? 1.0 : 0.0 }
        let dcg = grades.enumerated().reduce(0.0) { $0 + $1.element / log2(Double($1.offset + 2)) }
        // Multiple gold quotations may live in one passage. nDCG's ideal
        // ranking counts relevant passages, while recall counts gold spans.
        let relevantUnitCount = referenceUnits.reduce(0) { total, pair in
            total + pair.value.filter { chunk in expected.contains { evidence in
                pair.key == corpus.sources.first { $0.key == evidence.source }?.id &&
                    chunk.lower < evidence.characterEnd && chunk.upper > evidence.characterStart
            } }.count
        }
        let ideal = (0..<min(8, relevantUnitCount)).reduce(0.0) { $0 + 1 / log2(Double($1 + 2)) }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return ["case_id": row.caseId, "category": row.category, "variant": variant, "recall_at_8": Double(recalled) / Double(expected.count),
                "ndcg_at_8": min(1, ideal > 0 ? dcg / ideal : 0), "returned_count": hits.count,
                "latency_ms": seconds * 1000, "reranker": reranker, "scope_valid": hits.allSatisfy { hit in row.focus.contains { key in corpus.sources.first { $0.key == key }?.id == hit["source_id"] as? String } }]
    }
    #endif
}
