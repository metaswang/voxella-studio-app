import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@Suite("Canonical knowledge and preserved media")
struct KnowledgeCanonicalRetrievalTests {
    private let fixtures = KnowledgeEvidenceWorkspaceTests()

    @Test func textOnlyTranscriptWinsWithoutBorrowingSubtitleTiming() throws {
        var source = fixtures.fixture()
        source.transcript = .init(text: "The current decision is October.", language: "en", words: [], segments: [])
        source.subtitleTrack = track("Outdated September")
        let body = try #require(KnowledgeTranscriptMaterial.from(source))
        #expect(body.text == "The current decision is October.")
        #expect(body.provenance == "original_segments")
        #expect(body.spans.allSatisfy { $0.start == nil && $0.end == nil })
    }

    @Test func originalSourceDoesNotBorrowLinkedDubAndVoiceoverSelectsOwnRevision() throws {
        var source = fixtures.fixture()
        source.dubTranscript = .init(text: "Dub only", language: "en", words: [], segments: [])
        #expect(KnowledgeTranscriptMaterial.from(source) == nil)
        source.source = .standaloneDub; source.sessionType = .dub; source.knowledgeRevisionID = UUID()
        let body = try #require(KnowledgeTranscriptMaterial.from(source))
        #expect(body.role == "voiceover")
        #expect(body.revision == source.knowledgeRevisionID?.uuidString)
        #expect(body.text == "Dub only")
    }

    @Test func partialTranscriptIsNotFilledWithSubtitles() throws {
        var source = fixtures.fixture(segments: [.init(text: "Known beginning", start: 1, end: 4)])
        source.subtitleTrack = track("Additional ending")
        #expect(KnowledgeTranscriptMaterial.from(source)?.text == "Known beginning")
    }

    @Test func subtitleFallbackRetainsCueMappingAndInvalidTimesRetainText() throws {
        var source = fixtures.fixture()
        source.subtitleTrack = track("Only subtitles", start: 20, end: 24)
        let body = try #require(KnowledgeTranscriptMaterial.from(source))
        #expect(body.provenance == "subtitle_fallback")
        #expect(body.spans.first?.cueID == 7)
        source.subtitleTrack?.cues[0].end = 0
        let invalid = try #require(KnowledgeTranscriptMaterial.from(source))
        #expect(invalid.text == "Only subtitles")
        #expect(invalid.spans.first?.start == nil)
    }

    @Test func editedTranscriptNeverReconstructsOldWords() throws {
        let result = TranscriptionResult(text: "Current decision", language: "en",
            words: [.init(text: "Old decision", start: 0, end: 2, timingQuality: .aligned)],
            segments: [.init(text: "Old decision", start: 0, end: 2)])
        let body = try #require(KnowledgeTranscriptMaterial.from(transcript: result))
        #expect(body.text == "Current decision")
        #expect(body.spans.allSatisfy { $0.start == nil })
    }

    @Test func verifiedWordsRefineLongParentAndKeepOriginalSegmentCount() throws {
        let words = (0..<100).map { TranscriptionWord(text: "word\($0)", start: Double($0), end: Double($0 + 1), timingQuality: .aligned) }
        let text = words.map(\.text).joined(separator: " ")
        let body = try #require(KnowledgeTranscriptMaterial.from(transcript: .init(text: text, language: "en", words: words,
            segments: [.init(text: text, start: 0, end: 100)])))
        #expect(body.segments.count == 1)
        let chunks = KnowledgeBodyChunker.pack(body)
        #expect(chunks.count >= 2)
        #expect(chunks.first?.end ?? 100 < 100)
        #expect(chunks.allSatisfy { $0.timingPrecision == "word" })
    }

    @Test func thirtyThousandCharactersAndUnicodeAreFullyCoveredWithoutFabricatedTime() throws {
        let text = "HEAD " + String(repeating: "中英🙂e\u{301} without punctuation ", count: 1_200) + " TAIL"
        let body = try #require(KnowledgeTranscriptMaterial.from(transcript: .init(text: text, language: nil, words: [],
            segments: [.init(text: text, start: 5, end: 1_805)])))
        let chunks = KnowledgeBodyChunker.pack(body)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.allSatisfy { KnowledgeBodyChunker.conservativeCount($0.text) <= 768 })
        #expect(chunks.allSatisfy { $0.start == 5 && $0.end == 1_805 && $0.timingPrecision == "coarse" })
        #expect(chunks.allSatisfy { KnowledgeBodyChunker.conservativeCount($0.context) <= 64 })
    }

    @Test func longWordAlignmentPreservesSpeakerBoundariesAndEveryMappedWord() throws {
        let words = (0..<4_000).map { TranscriptionWord(text: "word\($0)", start: Double($0), end: Double($0 + 1),
            speaker: $0 < 2_000 ? "A" : "B", timingQuality: .aligned) }
        let text = words.map(\.text).joined(separator: " ")
        let body = try #require(KnowledgeTranscriptMaterial.from(transcript: .init(text: text, language: "en", words: words,
            segments: [.init(text: text, start: 0, end: 4_000)])))
        let chunks = KnowledgeBodyChunker.pack(body)
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.allSatisfy { $0.timingPrecision == "word" && $0.speakers.count == 1 })
        let mapped = Dictionary(grouping: chunks.flatMap(\.spans), by: \.lower).values.compactMap(\.first).sorted { $0.lower < $1.lower }
        #expect(mapped == body.spans)
        #expect(chunks.first?.start == 0 && chunks.last?.end == 4_000)
    }

    @Test func concurrentTokenizerReadersPreserveBodiesAndCancellation() async throws {
        let tokenizer = KnowledgeTextTokenizer()
        let texts = [String(repeating: "中文 English 🙂e\u{301}. ", count: 180), String(repeating: "Second readable source. ", count: 180)]
        let bodies = try texts.map { try #require(KnowledgeTranscriptMaterial.from(transcript: .init(text: $0, language: nil, words: [], segments: []))) }
        async let first = tokenizer.chunks(for: bodies[0])
        async let second = tokenizer.chunks(for: bodies[1])
        async let duplicate = tokenizer.chunks(for: bodies[0])
        let results = await (first, second, duplicate)
        #expect(results.0.map(\.text).joined() == texts[0])
        #expect(results.1.map(\.text).joined() == texts[1])
        #expect(results.0 == results.2)
        let cancelled = Task { await tokenizer.chunks(for: bodies[0]) }
        cancelled.cancel()
        #expect(await cancelled.value.isEmpty)
    }

    @Test func sentenceBoundaryIsVerifiedWhenPrefixTokenCountsAreNotMonotonic() throws {
        let body = try #require(KnowledgeTranscriptMaterial.from(transcript: .init(text: "a.b", language: "en", words: [], segments: [])))
        let counter: (String) -> Int = { $0 == "a." ? 900 : $0.utf8.count }
        let chunks = KnowledgeBodyChunker.pack(body, count: counter)
        #expect(chunks.map(\.text).joined() == body.text)
        #expect(chunks.allSatisfy { counter($0.text) <= KnowledgeBodyChunker.maximumTokens })
    }

    @Test func subtitleCuesAreGroupedForQAWhileClipWindowsRemainShort() throws {
        let cues = (0..<40).map { SubtitleCue(id: $0, sourceIDs: [$0], text: "Cue \($0).", start: Double($0 * 2), end: Double($0 * 2 + 2), speaker: "A") }
        let body = try #require(KnowledgeTranscriptMaterial.from(subtitles: .init(sourceLanguage: "en", language: "en", cues: cues)))
        let chunks = KnowledgeBodyChunker.pack(body)
        let clips = CuePacker.pack(cues: cues)
        #expect(chunks.count < clips.count)
        #expect(chunks.map(\.text).joined() == body.text)
        #expect(Set(chunks.flatMap { $0.spans.compactMap(\.cueID) }) == Set(cues.map(\.id)))
    }

    @Test @MainActor func mcpSubtitleReaderPreservesSavedCuesAcrossPages() async throws {
        var source = fixtures.fixture(segments: [.init(text: "Canonical transcript only", start: 0, end: 80)])
        let cues = (0..<40).map { SubtitleCue(id: 100 + $0, sourceIDs: [$0], text: "字幕 🙂 \($0).",
            start: Double($0 * 2) + 0.6, end: Double($0 * 2) + 1.7, speaker: "Speaker 1") }
        source.subtitleTrack = .init(sourceLanguage: "en", language: "en", cues: cues)
        let scope = fixtures.snapshot([source])
        let args: [String: Any] = ["source_id": source.id.uuidString, "material": "subtitles", "view": "cues", "limit": 7]
        var rows: [[String: Any]] = [], cursor: String?
        repeat {
            var request = args; request["cursor"] = cursor
            let page = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch", args: request, snapshot: scope))
            #expect(page["total_count"] as? Int == cues.count)
            rows += try #require(page["segments"] as? [[String: Any]])
            cursor = page["next_cursor"] as? String
        } while cursor != nil
        #expect(rows.count == cues.count)
        for (row, cue) in zip(rows, cues) {
            #expect(row["cue_id"] as? Int == cue.id)
            #expect(row["text"] as? String == cue.text)
            #expect(row["display_text"] as? String == TranscriptSegmenter.renderedSubtitleText(cue.text))
            #expect(row["start"] as? Double == cue.start)
            #expect(row["end"] as? Double == cue.end)
            #expect(row["speaker"] as? [String] == [cue.speaker!])
            #expect(row["timing_precision"] as? String == "cue")
            let locator = try MCPKnowledgeBaseTools.Locator.decode(try #require(row["evidence_id"] as? String))
            let body = try #require(KnowledgeTranscriptMaterial.from(subtitles: source.subtitleTrack))
            #expect((body.text as NSString).substring(with: NSRange(location: locator.lower, length: locator.upper - locator.lower)) == cue.text)
        }
        // Evidence retrieval still groups cues; original transcript remains independent.
        let passages = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch",
            args: ["source_id": source.id.uuidString, "material": "subtitles"], snapshot: scope))
        #expect(try #require(passages["total_count"] as? Int) < cues.count)
        let original = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch",
            args: ["source_id": source.id.uuidString], snapshot: scope))
        #expect((original["segments"] as? [[String: Any]])?.first?["text"] as? String == "Canonical transcript only")
    }

    @Test @MainActor func mcpCueReaderSelectsTranslationAndDoesNotBorrowMissingSubtitles() async throws {
        var source = fixtures.fixture(segments: [.init(text: "Transcript exists", start: 0, end: 10)])
        source.translationTracks = [.init(languageCode: "zh", track: .init(sourceLanguage: "en", language: "zh", cues: [
            .init(id: 9, sourceIDs: [1], text: "翻译第一行", start: 2.6, end: 5.7, speaker: "Speaker 1"),
            .init(id: 12, sourceIDs: [2], text: "翻译第二行", start: 6.1, end: 9.0, speaker: "Speaker 1")]))]
        let scope = fixtures.snapshot([source])
        let translated = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch", args: [
            "source_id": source.id.uuidString, "material": "translation", "language": "zh", "view": "cues"], snapshot: scope))
        #expect((translated["segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == ["翻译第一行", "翻译第二行"])
        let missing = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch", args: [
            "source_id": source.id.uuidString, "material": "subtitles", "view": "cues"], snapshot: scope))
        #expect(missing["status"] as? String == "unavailable")
        #expect((missing["segments"] as? [Any])?.isEmpty == true)
        #expect(await MCPKnowledgeBaseTools.execute(name: "fetch", args: [
            "source_id": source.id.uuidString, "view": "cues"], snapshot: scope).isError == true)
    }

    @Test func knowledgeRebuildPreservesClipIDsAndBothVisualVectorTables() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture(segments: [.init(text: "Original October", start: 0, end: 60)])
        source.subtitleTrack = track("Subtitle asset September")
        var snapshot = try snapshot(source)
        snapshot.hasVideo = true
        try await store.replaceLexical(snapshot: snapshot, clips: CuePacker.pack(cues: snapshot.cues))
        let oldClip = try #require(try await store.unitsNeedingEmbedding(sessionID: source.id).first { $0.kind == .mediaClip })
        for modality in [SessionIndexModality.video, .mixed] { try await store.upsertEmbedding(unitID: oldClip.id, modality: modality, vector: vector(0)) }
        source.transcript = .init(text: "Updated November", language: "en", words: [], segments: [.init(text: "Updated November", start: 0, end: 60)])
        snapshot = try self.snapshot(source); snapshot.hasVideo = true
        try await store.replaceLexical(snapshot: snapshot, clips: CuePacker.pack(cues: snapshot.cues))
        let clips = try await store.searchLexical(query: "September", kinds: [.mediaClip], filter: .init(sessionID: source.id))
        #expect(clips.map(\.unitID) == [oldClip.id])
        for modality in [SessionIndexModality.video, .mixed] {
            let hits = try await store.searchVector(vector: vector(0), modality: modality, filter: .init(sessionID: source.id), allowedKinds: [.mediaClip])
            #expect(hits.map(\.unitID) == [oldClip.id])
        }
        #expect(try await store.searchLexical(query: "November", kinds: [.transcriptChunk], filter: .init(sessionID: source.id)).count > 0)
        #expect(try await store.searchLexical(query: "Original", kinds: [.transcriptChunk], filter: .init(sessionID: source.id)).isEmpty)
    }

    @Test func legacyManifestMigrationKeepsUnchangedClipsAndReplacesChangedMedia() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture(segments: [.init(text: "Original body", start: 0, end: 60)])
        source.subtitleTrack = track("中文素材 September")
        var item = try snapshot(source); item.hasVideo = true
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        let old = try #require(try await store.unitsNeedingEmbedding(sessionID: source.id).first { $0.kind == .mediaClip })
        for modality in [SessionIndexModality.video, .mixed] { try await store.upsertEmbedding(unitID: old.id, modality: modality, vector: vector(0)) }
        let legacy = try SessionSQLite(url: directory.appendingPathComponent("index.sqlite"))
        try legacy.run("DELETE FROM index_lane_state")
        source.transcript = .init(text: "Updated body", language: "en", words: [], segments: [])
        item = try snapshot(source); item.hasVideo = true
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues), force: true)
        for modality in [SessionIndexModality.video, .mixed] {
            #expect(try await store.searchVector(vector: vector(0), modality: modality, filter: .init(sessionID: source.id), allowedKinds: [.mediaClip]).map(\.unitID) == [old.id])
        }
        #expect(try await store.searchLexical(query: "中文素材", kinds: [.mediaClip], filter: .init(sessionID: source.id)).map(\.unitID) == [old.id])
        try legacy.run("DELETE FROM index_lane_state")
        source.subtitleTrack = track("Changed asset October")
        item = try snapshot(source); item.hasVideo = true
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        #expect(try await store.searchVector(vector: vector(0), modality: .video, filter: .init(sessionID: source.id), allowedKinds: [.mediaClip]).isEmpty)
        #expect(try await store.searchLexical(query: "October", kinds: [.mediaClip], filter: .init(sessionID: source.id)).count == 1)
    }

    @Test func subtitleEditsPreserveTranscriptUnitsAndTranscriptArrivalPreservesClips() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture()
        source.subtitleTrack = track("Fallback September")
        let first = try snapshot(source)
        try await store.replaceLexical(snapshot: first, clips: CuePacker.pack(cues: first.cues))
        let fallback = try await store.searchLexical(query: "September", kinds: [.transcriptChunk], filter: .init(sessionID: source.id))
        #expect(fallback.first?.provenance == "subtitle_fallback")
        let clipID = try #require(try await store.searchLexical(query: "September", kinds: [.mediaClip], filter: .init()).first?.unitID)
        source.transcript = .init(text: "Authoritative October", language: "en", words: [], segments: [])
        var item = try snapshot(source)
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        #expect(try await store.searchLexical(query: "September", kinds: [.transcriptChunk], filter: .init()).isEmpty)
        #expect(try await store.searchLexical(query: "September", kinds: [.mediaClip], filter: .init()).first?.unitID == clipID)
        let before = try #require(try await store.searchLexical(query: "October", kinds: [.transcriptChunk], filter: .init()).first?.unitID)
        source.subtitleTrack?.cues[0].text = "Edited subtitle December"
        item = try snapshot(source)
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        #expect(try await store.searchLexical(query: "October", kinds: [.transcriptChunk], filter: .init()).first?.unitID == before)
        #expect(try await store.searchLexical(query: "December", kinds: [.mediaClip], filter: .init()).count > 0)
    }

    @Test func kindAndScopeAreFilteredBeforeTopThirtyNearestNeighbors() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var wanted = fixtures.fixture(segments: [.init(text: "Scope relevant answer", start: 0, end: 20)])
        wanted.subtitleTrack = track("Scope clip")
        let item = try snapshot(wanted)
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        for unit in try await store.unitsNeedingEmbedding(sessionID: wanted.id) {
            try await store.upsertEmbedding(unitID: unit.id, modality: .text, vector: vector(unit.kind == .transcriptChunk ? 1 : 0))
        }
        for index in 0..<36 {
            let source = fixtures.fixture(title: "Distractor \(index)", segments: [.init(text: "Other source", start: 0, end: 20)])
            let item = try snapshot(source)
            try await store.replaceLexical(snapshot: item, clips: [])
            for unit in try await store.unitsNeedingEmbedding(sessionID: source.id) {
                try await store.upsertEmbedding(unitID: unit.id, modality: .text, vector: vector(0))
            }
        }
        let hits = try await store.searchVector(vector: vector(0), modality: .text,
            filter: .init(sessionID: wanted.id), allowedKinds: [.transcriptChunk])
        #expect(hits.count == 1)
        #expect(hits.first?.sessionID == wanted.id)
        #expect(hits.first?.kind == .transcriptChunk)
    }

    @Test func clipOnlyTermsStayOutOfQAButRemainInMediaAndGenericSearch() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture(segments: [.init(text: "Transcript launch", start: 0, end: 20)])
        source.subtitleTrack = track("UniqueAssetKeyword")
        let item = try snapshot(source)
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        let service = SearchService(store: store, embeddings: nil)
        #expect(try await service.transcriptSearch(query: "UniqueAssetKeyword").isEmpty)
        #expect(try await service.clipSearch(query: "UniqueAssetKeyword").count > 0)
        #expect(try await service.search(query: "UniqueAssetKeyword").contains { $0.kind == .mediaClip })
    }

    @Test func textVideoMixedSemanticClipsAllRemainReachable() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture()
        source.subtitleTrack = track("Asset candidate")
        let item = try snapshot(source)
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        let clip = try #require(try await store.unitsNeedingEmbedding(sessionID: source.id).first { $0.kind == .mediaClip })
        for modality in SessionIndexModality.allCases { try await store.upsertEmbedding(unitID: clip.id, modality: modality, vector: vector(0)) }
        let service = SearchService(store: store, embeddings: FixtureEmbedding())
        let hits = try await service.clipSearch(query: "semantic unrelated terms")
        let hit = try #require(hits.first)
        #expect(hit.kind == .mediaClip)
        #expect(Set(hit.matchedModalities) == Set(["text", "video", "mixed"]))
    }

    @Test func mixedClipAddsMissingTextWithoutRecomputingVisualChannels() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture(); source.subtitleTrack = track("Asset candidate")
        var item = try snapshot(source); item.hasVideo = true
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        let clip = try #require(try await store.unitsNeedingEmbedding(sessionID: source.id).first { $0.kind == .mediaClip })
        for modality in [SessionIndexModality.video, .mixed] { try await store.upsertEmbedding(unitID: clip.id, modality: modality, vector: vector(0)) }
        #expect(try await store.missingEmbeddingModalities(for: clip) == [.text])
        try await store.upsertEmbedding(unitID: clip.id, modality: .text, vector: vector(1))
        #expect(try await store.missingEmbeddingModalities(for: clip).isEmpty)
        #expect(try await store.unitsNeedingEmbedding(sessionID: source.id).allSatisfy { $0.id != clip.id })
        for modality in [SessionIndexModality.video, .mixed] {
            #expect(try await store.searchVector(vector: vector(0), modality: modality, filter: .init(sessionID: source.id), allowedKinds: [.mediaClip]).map(\.unitID) == [clip.id])
        }
    }

    @Test func silentVideoWithoutTranscriptUsesRealMediaDurationAndVideoOnlyWindows() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (220, 30, 30), seconds: 1.2)])
        defer { try? FileManager.default.removeItem(at: url) }
        var source = fixtures.fixture(); source.sourceURL = url; source.durationHint = nil
        var item = try snapshot(source)
        #expect(item.cues.isEmpty && item.selectedBody == nil && item.hasVideo)
        await item.resolveVideoDurationIfNeeded()
        #expect(abs(item.duration - 1.2) < 0.1)
        #expect(item.mediaDurationSec != nil && item.durationProvenance == "media_metadata")
        let windows = CuePacker.videoOnlyWindows(duration: item.duration)
        #expect(windows.count == 1 && windows[0].text.isEmpty && windows[0].end > 1)
    }

    @Test func cjkAndEnglishNaturalQueriesRecallPartialMatches() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = fixtures.fixture(segments: [.init(text: "项目决定延期到十月。 Alice releases version 2.1", start: 0, end: 20)])
        let item = try snapshot(source)
        try await store.replaceLexical(snapshot: item, clips: [])
        #expect(try await store.searchLexical(query: "项目为何延期", kinds: [.transcriptChunk], filter: .init()).count > 0)
        #expect(try await store.searchLexical(query: "When does Alice release?", kinds: [.transcriptChunk], filter: .init()).count > 0)
    }

    @Test @MainActor func explicitMCPSubtitleSearchRetainsTextAndCanonicalSearchDoesNotMixIt() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = fixtures.fixture(segments: [.init(text: "Canonical October", start: 0, end: 20)])
        source.subtitleTrack = track("Subtitle September")
        let item = try snapshot(source)
        try await store.replaceLexical(snapshot: item, clips: CuePacker.pack(cues: item.cues))
        let service = SearchService(store: store, embeddings: nil), scope = fixtures.snapshot([source])
        let canonical = try payload(await MCPKnowledgeBaseTools.execute(name: "search",
            args: ["query": "September", "rerank": "none"], snapshot: scope, service: service))
        #expect((canonical["results"] as? [Any])?.isEmpty == true)
        let subtitles = try payload(await MCPKnowledgeBaseTools.execute(name: "search",
            args: ["query": "September", "target": "subtitle_passages", "rerank": "none"], snapshot: scope, service: service))
        #expect((subtitles["results"] as? [Any])?.count == 1)
        let media = try payload(await MCPKnowledgeBaseTools.execute(name: "search",
            args: ["query": "September", "target": "media_clips"], snapshot: scope, service: service))
        #expect((media["results"] as? [Any])?.count == 1)
    }

    @Test @MainActor func mcpLiteralCountsAndCrossBoundaryMatchesAreOccurrences() async throws {
        let source = fixtures.fixture(segments: [.init(text: "Launch October. Launch", start: 1, end: 2),
            .init(text: " October. Launch October.", start: 3, end: 4)])
        let result = try payload(await MCPKnowledgeBaseTools.execute(name: "find_text",
            args: ["text": "Launch October"], snapshot: fixtures.snapshot([source])))
        #expect(result["occurrence_count"] as? Int == 3)
        #expect(result["matched_segment_count"] as? Int == 2)
        #expect(result["matched_source_count"] as? Int == 1)
    }

    @Test @MainActor func mcpFetchRejectsStaleEvidenceAndCursorWithoutLosingTail() async throws {
        var source = fixtures.fixture(segments: [.init(text: String(repeating: "original text ", count: 500) + "TAIL", start: 0, end: 1_800)])
        let scope = fixtures.snapshot([source])
        let first = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch", args: ["source_id": source.id.uuidString, "limit": 1], snapshot: scope))
        let rows = try #require(first["segments"] as? [[String: Any]])
        let id = try #require(rows.first?["evidence_id"] as? String)
        let cursor = try #require(first["next_cursor"] as? String)
        var text = rows.compactMap { $0["text"] as? String }.joined()
        var next: String? = cursor
        while let current = next {
            let page = try payload(await MCPKnowledgeBaseTools.execute(name: "fetch",
                args: ["source_id": source.id.uuidString, "cursor": current, "limit": 32], snapshot: scope))
            text += (page["segments"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            next = page["next_cursor"] as? String
        }
        #expect(text == source.transcript?.text)
        source.transcript = .init(text: "Changed current body", language: "en", words: [], segments: [])
        let changed = fixtures.snapshot([source])
        #expect(await MCPKnowledgeBaseTools.execute(name: "fetch", args: ["evidence_id": id], snapshot: changed).isError == true)
        #expect(await MCPKnowledgeBaseTools.execute(name: "fetch", args: ["source_id": source.id.uuidString, "cursor": cursor], snapshot: changed).isError == true)
    }

    @Test @MainActor func mcpSchemasReadOnlyAndStructuredTextMirror() async throws {
        #expect(Set(MCPKnowledgeBaseTools.tools.map(\.name)) == Set(["search", "fetch", "list_sources", "aggregate", "find_text", "methods"]))
        #expect(MCPKnowledgeBaseTools.tools.allSatisfy { $0.annotations.readOnlyHint == true && $0.annotations.destructiveHint == false && $0.outputSchema != nil })
        let source = fixtures.fixture()
        let response = await MCPKnowledgeBaseTools.execute(name: "list_sources", args: [:], snapshot: fixtures.snapshot([source]))
        #expect(response.isError != true)
        guard case .text(let text, _, _) = response.content.first else { Issue.record("Missing JSON"); return }
        #expect(try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == response.structuredContent)
        #expect(await MCPKnowledgeBaseTools.execute(name: "fetch", args: ["source_id": UUID().uuidString], snapshot: fixtures.snapshot([source])).isError == true)
        #expect(await MCPKnowledgeBaseTools.execute(name: "search", args: ["query": "anything", "origin": "invalid"]).isError == true)
    }

    private func track(_ text: String, start: Double = 0, end: Double = 10) -> SubtitleTrack {
        .init(sourceLanguage: "en", language: "en", cues: [.init(id: 7, sourceIDs: [7], text: text, start: start, end: end, speaker: "A")])
    }
    private func snapshot(_ source: WorkbenchSession) throws -> SessionIndexSnapshot {
        try #require(SessionIndexSnapshot.from(session: source, sourceOrigin: .local, ownerUserID: nil))
    }
    private func makeStore() throws -> (SessionIndexStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-canonical-\(UUID())")
        return (try SessionIndexStore(url: directory.appendingPathComponent("index.sqlite")), directory)
    }
    private func vector(_ coordinate: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: 256); vector[coordinate] = 1; return vector
    }
    private func payload(_ result: CallTool.Result) throws -> [String: Any] {
        #expect(result.isError != true)
        guard case .text(let text, _, _) = result.content.first else { throw KnowledgeToolError.invalidParameter("No payload") }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private struct FixtureEmbedding: TextEmbeddingProvider {
        func encodeText(_ text: String) async throws -> [Float] {
            var vector = [Float](repeating: 0, count: 256); vector[0] = 1; return vector
        }
    }
}
