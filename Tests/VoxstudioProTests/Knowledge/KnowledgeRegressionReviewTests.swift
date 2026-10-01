import Foundation
import Testing
@testable import VoxstudioPro

struct KnowledgeRegressionReviewTests {
    private let fixtures = KnowledgeEvidenceWorkspaceTests()

    @Test func actualRegressionDatasetHasReadableTargetWindowsAndTruthfulMediaExtrema() async throws {
        guard ProcessInfo.processInfo.environment["VOXSTUDIO_KB_REVIEW_DATASET"] == "1" else { return }
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOXSTUDIO_KNOWLEDGE_WORKBENCH"] ??
            "/Users/adamwang/Library/Application Support/VoxStudio/workbench.json")
        let saved = try JSONDecoder().decode(WorkbenchSnapshot.self, from: Data(contentsOf: url))
        let sources = saved.transcriptions.filter { $0.storage == .local && $0.remoteSessionID == nil }.map { job in
            var source = fixtures.fixture(title: job.sessionTitle, segments: job.result?.segments)
            source.id = job.id; source.sourceURL = job.sourceURL; source.transcript = job.result
            source.subtitleTrack = job.subtitleTrack; source.summaryMarkdown = job.summaryMarkdown
            source.createdAt = job.createdAt; source.modifiedAt = job.modifiedAt
            return source
        }
        let executor = fixtures.makeExecutor(sources)
        let windows: [(String, Double, Double, String)] = [
            ("AI State of the Art & Future", 90, 174, "January 2025"),
            ("AI State of the Art & Future", 173, 239, "researchers are frequently changing jobs"),
            ("AI State of the Art & Future", 219, 239, "budget and hardware constraints"),
            ("Origin of Writing", 48, 144, "3500 BC"),
            ("High School Athletics & Activities Overview", 9, 103, "quit"),
            ("SAS Student Development and Parent Resources", 0, 92, "screen time"),
            ("When Life Gives You Lemons", 45, 104, "Write it down"),
            ("Rethinking Skills for Coding Agents", 0, 31, "bloated instructions")
        ]
        for (title, start, end, expected) in windows {
            let source = try #require(sources.first { $0.title.hasPrefix(title) })
            let result = try await executor.executeNative(name: "session_get_segments", inputJSON: KnowledgeJSON.encode([
                "session_id": source.id.uuidString, "start": start, "end": end]))
            #expect(!result.isError && result.json.contains(expected))
            #expect(try object(result)["complete"] as? Bool == true)
        }
        let duration = try await executor.executeNative(name: "session_aggregate", inputJSON: #"{"has_transcript":true,"sort_by":"duration","limit":1}"#)
        let aggregate = try #require(try object(duration)["aggregate"] as? [String: Any])
        let longest = try #require(aggregate["longest_known"] as? [String: Any])
        #expect(longest["title"] as? String == "Origin of Writing")
        let shortest = try #require(aggregate["shortest_known"] as? [String: Any])
        #expect((longest["media_duration_sec"] as? Double ?? 0) > 3_600)
        // The long AI/Infinity originals have been removed on this machine.
        // Their transcript endpoints must not turn into measured media lengths.
        #expect((aggregate["duration_unknown_count"] as? Int ?? 0) > 0)
        let ai = try #require(sources.first { $0.title == "AI State of the Art & Future" })
        if !FileManager.default.fileExists(atPath: ai.sourceURL?.path ?? "") {
            #expect(await KnowledgeMediaDurationCache.shared.knownFacts(for: ai).mediaDuration == nil)
        }
        print("KB review local dataset: sources=\(sources.count), known=\(aggregate["duration_known_count"] ?? "?"), unknown=\(aggregate["duration_unknown_count"] ?? "?"), longest=\(longest["title"] ?? "?") \(longest["media_duration_sec"] ?? "?")s, shortest=\(shortest["title"] ?? "?") \(shortest["media_duration_sec"] ?? "?")s")
        let literal = try await executor.executeNative(name: "knowledge_find_text", inputJSON: #"{"text":"Thank you","limit":100}"#)
        let literalData = try object(literal)
        #expect(literalData["complete"] as? Bool == true)
        #expect((literalData["matched_source_count"] as? Int ?? 0) > 3)
        print("KB review literal dataset: sources=\(literalData["matched_source_count"] ?? "?"), matches=\(literalData["total_count"] ?? "?")")
    }

    @Test func durationRankingReturnsSortedRowsAndProbesMediaAcrossTheFilteredSet() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try silentWAV(seconds: 2).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var short = fixtures.fixture(title: "Probed short", segments: [.init(text: "partial", start: 0, end: 999)])
        short.sourceURL = url
        let long = fixtures.fixture(title: "Known long", duration: 60, segments: [.init(text: "content", start: 0, end: 10)])
        let unavailable = fixtures.fixture(title: "Unknown", segments: [.init(text: "content", start: 0, end: 100)])
        let metadataOnly = fixtures.fixture(title: "No transcript", duration: 10_000)
        let executor = fixtures.makeExecutor([metadataOnly, short, unavailable, long])
        let result = try await executor.executeNative(name: "session_aggregate", inputJSON: #"{"sort_by":"duration","has_transcript":true,"limit":1}"#)
        let data = try object(result)
        let rows = try #require(data["sessions"] as? [[String: Any]])
        let aggregate = try #require(data["aggregate"] as? [String: Any])
        #expect(rows.first?["session_id"] as? String == long.id.uuidString)
        #expect(aggregate["sorted_session_ids"] as? [String] == [long.id.uuidString])
        #expect(aggregate["count"] as? Int == 3)
        #expect(aggregate["duration_unknown_count"] as? Int == 1)
        let shortest = try #require(aggregate["shortest_known"] as? [String: Any])
        #expect(shortest["session_id"] as? String == short.id.uuidString)
        #expect(abs((shortest["media_duration_sec"] as? Double ?? 0) - 2) < 0.01)
        #expect(shortest["media_duration_provenance"] as? String == "local_media_metadata")
        let ascending = try await executor.executeNative(name: "session_aggregate", inputJSON: #"{"sort_by":"duration","sort_order":"asc","has_transcript":true}"#)
        let ascendingRows = try #require(try object(ascending)["sessions"] as? [[String: Any]])
        #expect(ascendingRows.compactMap { $0["session_id"] as? String } == [short.id.uuidString, long.id.uuidString, unavailable.id.uuidString])
    }

    @Test func oversizedOriginalSegmentCanBeReadToCompletionWithoutInventingTimes() async throws {
        let original = String(repeating: "完整原文🙂", count: 4_000)
        let source = fixtures.fixture(segments: [.init(text: original, start: 12, end: 200, speaker: "A")])
        let executor = fixtures.makeExecutor([source])
        var text = "", cursor = 0, complete = false, seen: Set<String> = []
        while !complete {
            let result = try await executor.executeNative(name: "session_get_segments", inputJSON: KnowledgeJSON.encode([
                "session_id": source.id.uuidString, "cursor": cursor, "limit": 1]))
            #expect(!result.isError)
            let data = try object(result)
            let rows = try #require(data["segments"] as? [[String: Any]])
            #expect(rows.count == 1)
            text += rows[0]["text"] as? String ?? ""
            #expect(rows[0]["start"] as? Double == 12 && rows[0]["end"] as? Double == 200)
            let citations = try #require(data["citations"] as? [[String: Any]])
            #expect(seen.insert(try #require(citations.first?["evidence_id"] as? String)).inserted)
            complete = data["complete"] as? Bool == true
            if !complete { cursor = try #require(data["next_cursor"] as? Int) }
        }
        #expect(text == original)
    }

    @Test func literalLookupTraversesAllSourcesAndHandlesSegmentBoundariesAndPaging() async throws {
        let a = fixtures.fixture(title: "Same title", segments: [.init(text: "Thank", start: 0, end: 2), .init(text: "you!", start: 2, end: 4)])
        let b = fixtures.fixture(title: "Same title", segments: [.init(text: "say THANK   YOU again", start: 7, end: 10)])
        let absent = fixtures.fixture(segments: [.init(text: "hello", start: 0, end: 1)])
        let unreadable = fixtures.fixture()
        let executor = fixtures.makeExecutor([a, b, absent, unreadable])
        let first = try await executor.executeNative(name: "knowledge_find_text", inputJSON: #"{"text":"Thank you","limit":1}"#)
        let data = try object(first)
        #expect(data["matched_source_count"] as? Int == 2)
        #expect(data["total_count"] as? Int == 3)
        #expect(data["checked_source_count"] as? Int == 3)
        #expect(data["all_sources_readable"] as? Bool == false)
        #expect(data["unavailable_source_ids"] as? [String] == [unreadable.id.uuidString])
        #expect(data["complete"] as? Bool == false)
        let last = try await executor.executeNative(name: "knowledge_find_text", inputJSON: #"{"text":"Thank you","cursor":2,"limit":1}"#)
        let lastData = try object(last)
        #expect(lastData["complete"] as? Bool == true)
        let hits = try #require(lastData["segments"] as? [[String: Any]])
        #expect(hits.first?["session_id"] as? String == b.id.uuidString)
        #expect(hits.first?["start"] as? Double == 7)
        let foreign = try await executor.executeNative(name: "knowledge_find_text", inputJSON: KnowledgeJSON.encode([
            "text": "Thank you", "session_ids": [UUID().uuidString]]))
        #expect(foreign.isError)
    }

    @Test func finalSourcesUseActualCitationNumbersAndMetadataCanBeRefreshed() async throws {
        let a = fixtures.fixture(), b = fixtures.fixture()
        let workspace = KnowledgeEvidenceWorkspace(snapshot: fixtures.snapshot([a, b]))
        let executor = KnowledgeToolExecutor(scope: .all, originFilter: nil, retrievalService: .init(), workspace: workspace)
        _ = try await executor.executeNative(name: "session_list", inputJSON: "{}")
        let result = try await executor.executeNative(name: "session_get_summary", inputJSON: KnowledgeJSON.encode(["session_id": b.id.uuidString]))
        let refs = try #require(try object(result)["citations"] as? [[String: Any]])
        let number = try #require(refs.first?["citation_number"] as? Int)
        let actual = await workspace.answerCitations("摘要说明了决定。[\(number)]")
        #expect(actual.count == 1 && actual.first?.sessionUUID == b.id)
        #expect(actual.first?.sourceType == "sessionSummary")
        #expect(KnowledgeCitationMarkers.numbers(in: "共有 4。2026 年 [2, 3]【7】") == [2, 3, 7])
        let ref = KnowledgeSourceRef(sourceID: a.id.uuidString, sourceType: "sessionCard", title: a.title,
            uri: nil, page: nil, startTime: nil, endTime: nil, parentID: nil, chunkIndex: -1,
            language: nil, speaker: nil, snippet: "resolved duration 90", matchText: nil)
        _ = await workspace.record(KnowledgeJSON.encode(["citations": [KnowledgeJSON.citation(ref)]]))
        #expect(await workspace.citations().first(where: { $0.id == ref.id })?.snippet == "resolved duration 90")
    }

    @Test func rawEvidenceCacheIsBoundedAndDoesNotDuplicateWorkspaceReferencesInEntries() async throws {
        let cache = KnowledgeEvidenceCache()
        let source = fixtures.fixture()
        let ref = KnowledgeSourceRef(sourceID: source.id.uuidString, sourceType: "sessionSummary", title: source.title,
            uri: nil, page: nil, startTime: nil, endTime: nil, parentID: nil, chunkIndex: -2,
            language: nil, speaker: nil, snippet: "evidence", matchText: nil)
        await cache.put(.init(json: "{}", isError: false, citations: [ref]), key: "entry")
        #expect(await cache.get("entry")?.citations.isEmpty == true)
        let memory = KnowledgeWorkspaceMemory(references: [ref], evidenceIDs: [:], payloads: [:], analysis: nil, readCoverage: [:])
        await cache.saveMemory(memory, key: "conversation")
        #expect(await cache.memory("conversation") != nil)
        let oversized = KnowledgeWorkspaceMemory(references: [ref], evidenceIDs: [:],
            payloads: ["large": String(repeating: "x", count: KnowledgeEvidenceCache.memoryByteLimit + 1)], analysis: nil, readCoverage: [:])
        await cache.saveMemory(oversized, key: "conversation")
        #expect(await cache.memory("conversation") == nil)
    }

    private func object(_ result: KnowledgeToolObservation) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
    }

    private func silentWAV(seconds: Int) -> Data {
        var data = Data()
        func bytes(_ text: String) { data.append(contentsOf: text.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let length = UInt32(seconds * 8_000 * 2)
        bytes("RIFF"); number(length + 36); bytes("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(8_000)); number(UInt32(16_000)); number(UInt16(2)); number(UInt16(16)); bytes("data"); number(length)
        data.append(Data(count: Int(length)))
        return data
    }
}
