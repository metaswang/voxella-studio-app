import Foundation
import Testing
@testable import PalmierPro

struct KnowledgeIndexEvidenceTests {
    @Test func oldDurationIsUnknownUntilMetadataOnlyRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-duration-\(UUID())")
        let store = try SessionIndexStore(url: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = snapshot()
        try await store.replaceLexical(snapshot: source, clips: [])
        let old = try #require(await store.durationFacts(sessionID: source.sessionID))
        #expect(old.media == nil)
        #expect(old.provenance == "legacy_unknown")
        let before = try await store.transcriptPage(filter: .init(sessionID: source.sessionID), offset: 0)
        try await store.patchMediaFacts(sessionID: source.sessionID, mediaDuration: 1_800, provenance: "local_media_metadata",
                                       lastSpokenEnd: 1_440, transcribedStart: 0, transcribedEnd: 1_440)
        let repaired = try #require(await store.durationFacts(sessionID: source.sessionID))
        #expect(repaired.media == 1_800)
        #expect(repaired.lastSpoken == 1_440)
        let after = try await store.transcriptPage(filter: .init(sessionID: source.sessionID), offset: 0)
        #expect(before.hits.map(\.unitID) == after.hits.map(\.unitID))
    }

    @Test func indexedConsecutivePagesHonorTimeSpeakerAndOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-index-page-\(UUID())")
        let store = try SessionIndexStore(url: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = snapshot()
        source.sourceOrigin = .cloud
        source.ownerUserID = "owner-a"
        try await store.replaceLexical(snapshot: source, clips: [])
        let wrongOwner = try await store.transcriptPage(filter: .init(sessionID: source.sessionID,
            sourceOrigins: [.cloud], cloudOwnerUserID: "owner-b", limit: 2), offset: 0)
        #expect(wrongOwner.total == 0)
        #expect(wrongOwner.hits.isEmpty)
        let allowed = SessionSearchFilter(sessionID: source.sessionID, sourceOrigins: [.cloud], cloudOwnerUserID: "owner-a", limit: 1)
        let first = try await store.transcriptPage(filter: allowed, offset: 0)
        #expect(first.total > 0)
        #expect(first.hits.count == 1)
        if first.total > 1 {
            let second = try await store.transcriptPage(filter: allowed, offset: 1)
            #expect(first.hits.first?.unitID != second.hits.first?.unitID)
        }
        var tail = allowed
        tail.start = 1_400
        let last = try await store.transcriptPage(filter: tail, offset: 0)
        #expect(last.hits.allSatisfy { ($0.end ?? 0) >= 1_400 })
        var empty = allowed
        empty.sourceOrigins = []
        #expect(try await store.transcriptPage(filter: empty, offset: 0).total == 0)
    }

    private func snapshot() -> SessionIndexSnapshot {
        .init(sessionID: UUID(), title: "Meeting", tag: nil, summaryMarkdown: nil, language: "zh", duration: 1_440,
              hasVideo: false, mediaPath: "/missing.wav", sourceMTime: nil, generation: 1,
              speakers: [.init(label: "A", displayName: "张三")],
              segments: [.init(text: "最初提议本周发布。", start: 0, end: 10, speaker: "A"),
                         .init(text: "最后决定延期。", start: 1_430, end: 1_440, speaker: "A")],
              words: [], cues: [], shotBounds: [])
    }
}
