import Foundation
import Testing
@testable import PalmierPro

@Suite("Cue packer")
struct CuePackerTests {
    @Test func neverSplitsACueAndKeepsEyeDescriptionTogether() {
        let cues = [
            cue(1, 0, 8.7, "脚底很痛", "Speaker 1"),
            cue(2, 8.7, 17.4, "颈椎按了之后松了", "Speaker 1"),
            cue(3, 22.16, 31.68, "眼前一亮，看得很远很亮", "Speaker 1"),
            cue(4, 34.83, 43.54, "在家里给孩子先生和老人使用", "Speaker 1"),
            cue(5, 43.54, 52.25, "转动和拉耳朵", "Speaker 1"),
        ]
        let clips = CuePacker.pack(cues: cues)
        #expect(clips.contains { $0.cueIDs == [3] || $0.text.contains("眼前一亮") })
        let eye = clips.first { $0.text.contains("眼前一亮") }
        #expect(eye?.start == 22.16)
        #expect(eye?.end == 31.68)
        let ear = clips.first { $0.text.contains("转动和拉耳朵") }
        #expect(ear != nil)
        #expect(ear!.start <= 43.54)
        #expect(ear!.end >= 52.25)
    }

    @Test func flushesOnHardSpeakerChangeAfterMinimumDuration() {
        let cues = [
            cue(1, 0, 5, "hello", "Speaker 1"),
            cue(2, 5.1, 10, "there", "Speaker 1"),
            cue(3, 10.2, 15, "reply", "Speaker 2"),
        ]
        let clips = CuePacker.pack(cues: cues)
        #expect(clips.count == 2)
        #expect(clips[0].speakerLabels == ["Speaker 1"])
        #expect(clips[1].speakerLabels == ["Speaker 2"])
    }

    @Test func keepsOversizedCueIntact() {
        let clips = CuePacker.pack(cues: [cue(1, 0, 25, "a very long line", "Speaker 1")])
        #expect(clips.count == 1)
        #expect(clips[0].start == 0)
        #expect(clips[0].end == 25)
    }

    private func cue(_ id: Int, _ start: Double, _ end: Double, _ text: String, _ speaker: String) -> SubtitleCue {
        SubtitleCue(id: id, sourceIDs: [], text: text, start: start, end: end, speaker: speaker)
    }
}

@Suite("Transcript chunk packer")
struct TranscriptChunkPackerTests {
    @Test func mergesShortSpeakerTurnsIntoOneChunk() {
        let chunks = TranscriptChunkPacker.pack(segments: [
            segment("嗯。", 0, 3, "Speaker 1"),
            segment("痛哪里？", 3.1, 6, "Speaker 2"),
            segment("脚底。", 6.2, 9, "Speaker 1"),
        ])
        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0)
        #expect(chunks[0].end == 9)
        #expect(chunks[0].speakerLabels == ["Speaker 1", "Speaker 2"])
        #expect(chunks[0].text.contains("脚底"))
    }

    @Test func flushesOnSpeakerChangeAfterMinimumDuration() {
        let chunks = TranscriptChunkPacker.pack(segments: [
            segment("独白一段", 0, 30, "Speaker 1"),
            segment("另一人继续说完最小窗", 30.2, 60, "Speaker 2"),
        ])
        #expect(chunks.count == 2)
        #expect(chunks[0].speakerLabels == ["Speaker 1"])
        #expect(chunks[1].speakerLabels == ["Speaker 2"])
    }

    @Test func attachesShortTrailingTurnToPreviousWindow() {
        let chunks = TranscriptChunkPacker.pack(segments: [
            segment("手法说明", 0, 30, "Speaker 1"),
            segment("好。", 31, 34, "Speaker 2"),
        ])
        #expect(chunks.count == 1)
        #expect(chunks[0].end == 34)
        #expect(chunks[0].speakerLabels == ["Speaker 1", "Speaker 2"])
    }

    @Test func keepsLongSegmentIntact() {
        let chunks = TranscriptChunkPacker.pack(segments: [
            segment("一整段独白不超过一分钟", 0, 60, "Speaker 1"),
        ])
        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0)
        #expect(chunks[0].end == 60)
    }

    @Test func prependsTrailingOverlapWithoutShiftingTimestamps() {
        let chunks = TranscriptChunkPacker.pack(segments: [
            segment("前半段内容", 0, 20, "Speaker 1"),
            segment("窗尾重叠", 20, 30, "Speaker 1"),
            segment("后窗正文", 33, 63, "Speaker 1"),
        ])
        #expect(chunks.count == 2)
        #expect(chunks[0].end == 30)
        #expect(chunks[1].start == 33)
        #expect(chunks[1].end == 63)
        #expect(chunks[1].text.contains("窗尾重叠"))
        #expect(chunks[1].text.contains("后窗正文"))
    }

    private func segment(_ text: String, _ start: Double, _ end: Double, _ speaker: String) -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: end, speaker: speaker)
    }
}

@Suite("Word span mapper")
struct WordSpanMapperTests {
    @Test func mapsOverlappingWordsAndTightensToQueryTerms() {
        let words = [
            word("眼前", 22.2, 22.6),
            word("一亮", 22.6, 23.1),
            word("看得", 26.0, 26.4),
            word("很远", 26.4, 26.8),
        ]
        let span = WordSpanMapper.quoteSpan(
            overlapping: 20 ... 30,
            matching: ["很远"],
            in: words
        )
        #expect(span?.start == 26.4)
        #expect(span?.end == 26.8)
        #expect(span?.words.map(\.text) == ["很远"])
    }
}

@Suite("Reciprocal rank fusion")
struct ReciprocalRankFusionTests {
    @Test func prefersItemsRankedHighInMultipleLists() {
        let fused = ReciprocalRankFusion.fuse(rankings: [
            ["a", "b", "c"],
            ["c", "a", "d"],
        ])
        #expect(fused.first == "a")
        #expect(Set(fused) == ["a", "b", "c", "d"])
    }
}

@Suite("Session index lexical search")
struct SessionIndexStoreTests {
    @Test func indexesTranscriptAndReturnsSpeakerTimestampHits() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionIndexStore(url: url)
        let sessionID = UUID()
        let snapshot = SessionIndexSnapshot(
            sessionID: sessionID,
            title: "手法治疗",
            tag: "research",
            summaryMarkdown: nil,
            language: "zh",
            duration: 52,
            hasVideo: true,
            mediaPath: "/tmp/demo.mp4",
            sourceMTime: 1,
            generation: 1,
            speakers: [SessionSpeaker(label: "Speaker 1", displayName: "Speaker 1")],
            segments: [
                TranscriptionSegment(text: "脚底很痛 走路站起来会痛", start: 0, end: 45, speaker: "Speaker 1"),
            ],
            words: [
                word("脚底", 0.5, 0.9),
                word("很痛", 0.9, 1.4),
            ],
            cues: [
                SubtitleCue(id: 1, sourceIDs: [], text: "脚底很痛", start: 0.4, end: 2.0, speaker: "Speaker 1"),
            ],
            shotBounds: []
        )
        try await store.replaceLexical(
            snapshot: snapshot,
            clips: CuePacker.pack(cues: snapshot.cues)
        )

        let hits = try await store.searchLexical(
            query: "脚底很痛",
            kinds: [.transcriptChunk],
            filter: SessionSearchFilter(sessionID: sessionID)
        )
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.speakerLabels.contains("Speaker 1") })
        #expect(hits.contains { $0.start != nil && $0.end != nil })

        let card = try await store.sessionCard(id: sessionID)
        #expect(card?.title == "手法治疗")
        #expect(card?.lexicalReady == true)
        #expect(card?.embeddingReady == false)
    }

    @Test func reportsFreshnessAndUnitsMissingEmbeddings() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionIndexStore(url: url)
        let snapshot = indexSnapshot(generation: 7)
        try await store.replaceLexical(snapshot: snapshot, clips: CuePacker.pack(cues: snapshot.cues))

        let freshness = try await store.freshness(sessionID: snapshot.sessionID)
        #expect(freshness == SessionIndexFreshness(generation: 7, lexicalReady: true, embeddingReady: false))
        #expect(try await store.sessionsNeedingEmbedding() == [snapshot.sessionID])

        let needed = try await store.unitsNeedingEmbedding(sessionID: snapshot.sessionID)
        #expect(!needed.isEmpty)
        #expect(Set(needed.map(\.kind)).isSubset(of: [
            .sessionCard, .transcriptChunk, .mediaClip,
        ]))

        let card = try #require(needed.first { $0.kind == .sessionCard })
        try await store.upsertEmbedding(unitID: card.id, modality: .text, vector: dummyVector(0.1))
        let remaining = try await store.unitsNeedingEmbedding(sessionID: snapshot.sessionID)
        #expect(!remaining.contains { $0.id == card.id })

        try await store.markEmbeddingReady(snapshot.sessionID, ready: true)
        #expect(try await store.sessionsNeedingEmbedding().isEmpty)
        #expect(try await store.freshness(sessionID: snapshot.sessionID)?.embeddingReady == true)
    }

    @Test func cardPatchInvalidatesSessionCardEmbedding() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionIndexStore(url: url)
        var snapshot = indexSnapshot(generation: 1)
        try await store.replaceLexical(snapshot: snapshot, clips: [])
        let card = try #require(
            try await store.unitsNeedingEmbedding(sessionID: snapshot.sessionID)
                .first { $0.kind == .sessionCard }
        )
        try await store.upsertEmbedding(unitID: card.id, modality: .text, vector: dummyVector(0.2))
        try await store.markEmbeddingReady(snapshot.sessionID, ready: true)

        snapshot.title = "更新标题"
        snapshot.summaryMarkdown = "新摘要"
        try await store.patchSessionCard(snapshot: snapshot)

        let freshness = try await store.freshness(sessionID: snapshot.sessionID)
        #expect(freshness?.embeddingReady == false)
        let needed = try await store.unitsNeedingEmbedding(sessionID: snapshot.sessionID)
        #expect(needed.contains { $0.kind == .sessionCard && $0.id == card.id })
    }

    @Test func packsShortTurnsAndDoesNotIndexSubtitleCues() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SessionIndexStore(url: url)
        var snapshot = indexSnapshot(generation: 1)
        snapshot.speakers = [
            SessionSpeaker(label: "Speaker 1", displayName: "Speaker 1"),
            SessionSpeaker(label: "Speaker 2", displayName: "Speaker 2"),
        ]
        snapshot.segments = [
            TranscriptionSegment(text: "嗯。", start: 0, end: 3, speaker: "Speaker 1"),
            TranscriptionSegment(text: "痛哪里？", start: 3.1, end: 6, speaker: "Speaker 2"),
            TranscriptionSegment(text: "脚底。", start: 6.2, end: 9, speaker: "Speaker 1"),
        ]
        snapshot.cues = [
            SubtitleCue(id: 9, sourceIDs: [], text: "字幕独有句", start: 0.4, end: 1.2, speaker: "Speaker 1"),
        ]
        try await store.replaceLexical(snapshot: snapshot, clips: CuePacker.pack(cues: snapshot.cues))

        let needed = try await store.unitsNeedingEmbedding(sessionID: snapshot.sessionID)
        let chunks = needed.filter { $0.kind == .transcriptChunk }
        #expect(chunks.count == 1)
        #expect(chunks[0].speakers.contains("Speaker 1"))
        #expect(chunks[0].speakers.contains("Speaker 2"))

        let cueHits = try await store.searchLexical(
            query: "字幕独有句",
            kinds: [.transcriptChunk],
            filter: SessionSearchFilter(sessionID: snapshot.sessionID)
        )
        #expect(cueHits.isEmpty)
    }
}

@Suite("Session index ingest action")
struct SessionIndexIngestActionTests {
    @Test func replacesMissingStaleOrUnreadyLexical() {
        #expect(SessionIndexIngestAction.resolve(freshness: nil, generation: 1) == .replace)
        #expect(
            SessionIndexIngestAction.resolve(
                freshness: SessionIndexFreshness(generation: 1, lexicalReady: false, embeddingReady: false),
                generation: 1
            ) == .replace
        )
        #expect(
            SessionIndexIngestAction.resolve(
                freshness: SessionIndexFreshness(generation: 1, lexicalReady: true, embeddingReady: true),
                generation: 2
            ) == .replace
        )
    }

    @Test func embedsWhenLexicalIsCurrentAndVectorsAreMissing() {
        #expect(
            SessionIndexIngestAction.resolve(
                freshness: SessionIndexFreshness(generation: 4, lexicalReady: true, embeddingReady: false),
                generation: 4
            ) == .embedOnly
        )
    }

    @Test func skipsWhenLexicalAndEmbeddingsAreCurrent() {
        #expect(
            SessionIndexIngestAction.resolve(
                freshness: SessionIndexFreshness(generation: 4, lexicalReady: true, embeddingReady: true),
                generation: 4
            ) == .skip
        )
    }

    @Test func formatBumpRebuildsHistoricalMtimeGenerations() {
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let generation = SessionIndexSnapshot.generation(modifiedAt: modifiedAt)
        #expect(generation == SessionIndexSnapshot.ingestFormat &* 1_000_000_000_000 + 1_700_000_000)
        #expect(
            SessionIndexIngestAction.resolve(
                freshness: SessionIndexFreshness(
                    generation: Int(modifiedAt.timeIntervalSince1970),
                    lexicalReady: true,
                    embeddingReady: true
                ),
                generation: generation
            ) == .replace
        )
    }
}

@Suite("Session index eligibility")
struct SessionIndexEligibilityTests {
    @Test func snapshotOnlyComesFromCompletedJobsWithTranscript() {
        let result = TranscriptionResult(
            text: "脚底很痛",
            language: "zh",
            words: [word("脚底", 0.5, 0.9)],
            segments: [TranscriptionSegment(text: "脚底很痛", start: 0, end: 2, speaker: "Speaker 1")]
        )
        for state: WorkbenchJobState in [.ready, .running, .cancelling, .cancelled, .failed] {
            let job = indexJob(state: state, result: result)
            #expect(SessionIndexSnapshot.from(job) == nil)
        }
        #expect(SessionIndexSnapshot.from(indexJob(state: .completed, result: result)) != nil)
    }

    @Test func snapshotRejectsCompletedJobsWithoutTranscriptOrCues() {
        #expect(SessionIndexSnapshot.from(indexJob(state: .completed, result: nil)) == nil)
    }
}

private func indexJob(
    state: WorkbenchJobState,
    result: TranscriptionResult?
) -> WorkbenchTranscriptionJob {
    WorkbenchTranscriptionJob(
        sourcePath: "/tmp/demo.mp4",
        state: state,
        result: result
    )
}

private func indexSnapshot(generation: Int) -> SessionIndexSnapshot {
    let sessionID = UUID()
    return SessionIndexSnapshot(
        sessionID: sessionID,
        title: "手法治疗",
        tag: "research",
        summaryMarkdown: nil,
        language: "zh",
        duration: 52,
        hasVideo: true,
        mediaPath: "/tmp/demo.mp4",
        sourceMTime: Double(generation),
        generation: generation,
        speakers: [SessionSpeaker(label: "Speaker 1", displayName: "Speaker 1")],
        segments: [
            TranscriptionSegment(text: "脚底很痛 走路站起来会痛", start: 0, end: 45, speaker: "Speaker 1"),
        ],
        words: [
            word("脚底", 0.5, 0.9),
            word("很痛", 0.9, 1.4),
        ],
        cues: [
            SubtitleCue(id: 1, sourceIDs: [], text: "脚底很痛", start: 0.4, end: 2.0, speaker: "Speaker 1"),
        ],
        shotBounds: []
    )
}

private func dummyVector(_ seed: Float) -> [Float] {
    (0..<SessionIndexStore.embeddingDimension).map { seed + Float($0) * 0.0001 }
}

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
    TranscriptionWord(text: text, start: start, end: end, speaker: "Speaker 1")
}
