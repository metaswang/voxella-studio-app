import Foundation
import Testing
@testable import PalmierPro

struct KnowledgeChatStoreTests {
    @Test
    func conversationsAreIsolatedByScope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-chat-\(UUID().uuidString)", isDirectory: true)
        let store = KnowledgeChatStore(rootURL: root)

        let sessionA = UUID()
        let sessionB = UUID()
        let all = try await store.conversation(for: .all)
        let a = try await store.conversation(for: .session(sessionA))
        let b = try await store.conversation(for: .session(sessionB))

        #expect(all.id != a.id)
        #expect(a.id != b.id)
        #expect(all.scope == .all)
        #expect(a.scope == .session(sessionA))
        #expect(b.scope == .session(sessionB))

        try await store.append(
            KnowledgeMessage(conversationID: all.id, role: .user, content: "all-q")
        )
        try await store.append(
            KnowledgeMessage(conversationID: a.id, role: .user, content: "a-q")
        )

        let allMessages = try await store.messages(for: all.id)
        let aMessages = try await store.messages(for: a.id)
        let bMessages = try await store.messages(for: b.id)

        #expect(allMessages.map(\.content) == ["all-q"])
        #expect(aMessages.map(\.content) == ["a-q"])
        #expect(bMessages.isEmpty)

        let all2 = try await store.conversation(for: .all)
        let a2 = try await store.conversation(for: .session(sessionA))
        #expect(all2.id == all.id)
        #expect(a2.id == a.id)
    }

    @Test
    func removeMessageDeletesFromStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-remove-\(UUID().uuidString)", isDirectory: true)
        let store = KnowledgeChatStore(rootURL: root)
        let conversation = try await store.conversation(for: .all)
        let userID = UUID()
        let user = KnowledgeMessage(id: userID, conversationID: conversation.id, role: .user, content: "test")
        try await store.append(user)
        let before = try await store.messages(for: conversation.id)
        #expect(before.count == 1)
        try await store.removeMessage(id: userID, conversationID: conversation.id)
        let after = try await store.messages(for: conversation.id)
        #expect(after.isEmpty)
    }
}


struct KnowledgeQAScopeTests {
    @Test
    func fromSelectionNormalizesCounts() {
        let a = UUID()
        let b = UUID()
        #expect(KnowledgeQAScope.fromSelection([]) == .all)
        #expect(KnowledgeQAScope.fromSelection([a]) == .session(a))
        let multi = KnowledgeQAScope.fromSelection([a, b, a])
        #expect(multi == .sessions([a, b]))
        #expect(multi.sessionIDs == [a, b])
    }

    @Test
    func storageKeyIsOrderStable() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let left = KnowledgeQAScope.sessions([a, b])
        let right = KnowledgeQAScope.sessions([b, a])
        #expect(left.storageKey == right.storageKey)
        #expect(left == right)
    }
}

struct KnowledgeMultiScopeChatStoreTests {
    @Test
    func multiSessionConversationIsIsolated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-multi-\(UUID().uuidString)", isDirectory: true)
        let store = KnowledgeChatStore(rootURL: root)
        let a = UUID()
        let b = UUID()
        let multi = KnowledgeQAScope.fromSelection([a, b])
        let single = KnowledgeQAScope.session(a)
        let m = try await store.conversation(for: multi)
        let s = try await store.conversation(for: single)
        let all = try await store.conversation(for: .all)
        #expect(m.id != s.id)
        #expect(m.id != all.id)
        try await store.append(KnowledgeMessage(conversationID: m.id, role: .user, content: "multi-q"))
        let again = try await store.conversation(for: KnowledgeQAScope.fromSelection([b, a]))
        #expect(again.id == m.id)
        let messages = try await store.messages(for: again.id)
        #expect(messages.map(\.content) == ["multi-q"])
        #expect(try await store.messages(for: s.id).isEmpty)
    }
}

struct KnowledgeQAServiceHelpersTests {
    @Test
    func citationMapsSessionAndTimestamp() {
        let sessionID = UUID()
        let hit = SessionSearchHit(
            sessionID: sessionID,
            title: "Weekly sync",
            unitID: 42,
            kind: .transcriptChunk,
            start: 125,
            end: 140,
            speakerLabels: ["Alice"],
            text: "We should ship knowledge QA this week.",
            score: 0.9,
            matchSource: "bm25",
            snippet: "ship knowledge QA",
            cueIDs: [],
            hasVideo: false,
            language: "en",
            quoteSpan: nil
        )
        let citation = KnowledgeQAService.citation(from: hit)
        #expect(citation.sourceID == sessionID.uuidString)
        #expect(citation.sourceType == "sessionTranscript")
        #expect(citation.title == "Weekly sync")
        #expect(citation.speaker == "Alice")
        #expect(citation.timestampLabel == "2:05")
        #expect(citation.chipLabel.contains("Weekly sync"))
        #expect(citation.chipLabel.contains("2:05"))
    }

    @Test
    func citationMapsKindToAccurateSourceType() {
        let sessionID = UUID()
        let transcript = SessionSearchHit(
            sessionID: sessionID, title: "T", unitID: 1, kind: .transcriptChunk,
            start: 0, end: 10, speakerLabels: [], text: "text", score: 1,
            matchSource: "bm25", snippet: nil, cueIDs: [], hasVideo: false, language: nil, quoteSpan: nil
        )
        let clip = SessionSearchHit(
            sessionID: sessionID, title: "C", unitID: 2, kind: .mediaClip,
            start: 20, end: 30, speakerLabels: [], text: "clip", score: 1,
            matchSource: "bm25", snippet: nil, cueIDs: [], hasVideo: false, language: nil, quoteSpan: nil
        )
        let card = SessionSearchHit(
            sessionID: sessionID, title: "Card", unitID: 3, kind: .sessionCard,
            start: nil, end: nil, speakerLabels: [], text: "summary", score: 1,
            matchSource: "summary", snippet: nil, cueIDs: [], hasVideo: false, language: nil, quoteSpan: nil
        )
        #expect(KnowledgeQAService.citation(from: transcript).sourceType == "sessionTranscript")
        #expect(KnowledgeQAService.citation(from: clip).sourceType == "mediaClip")
        #expect(KnowledgeQAService.citation(from: card).sourceType == "sessionCard")
    }

    @Test
    func buildContextRespectsMaxCharsAndKeepsOrder() {
        let hits = (0..<5).map { index in
            SessionSearchHit(
                sessionID: UUID(),
                title: "S\(index)",
                unitID: index,
                kind: .transcriptChunk,
                start: Double(index * 10),
                end: Double(index * 10 + 5),
                speakerLabels: [],
                text: String(repeating: "word\(index) ", count: 40),
                score: 1,
                matchSource: "bm25",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            )
        }
        let context = KnowledgeQAService.buildContext(hits: hits, maxChars: 350)
        #expect(context.contains("[1]"))
        #expect(!context.isEmpty)
        #expect(context.count <= 450)
    }

    @Test
    func chunkForStreamingCoversFullText() {
        let text = "Hello knowledge base streaming answer."
        let chunks = KnowledgeQAService.chunkForStreaming(text, chunkSize: 8)
        #expect(chunks.joined() == text)
        #expect(chunks.count > 1)
    }

    @Test
    func systemPromptReflectsOriginFilter() {
        let allLocal = KnowledgeQAService.systemPrompt(
            mode: .normal,
            scope: .all,
            originFilter: [.local]
        )
        #expect(allLocal.contains("local knowledge base"))
        let allCloud = KnowledgeQAService.systemPrompt(
            mode: .normal,
            scope: .all,
            originFilter: [.cloud]
        )
        #expect(allCloud.contains("cloud knowledge base"))
        let allBoth = KnowledgeQAService.systemPrompt(
            mode: .normal,
            scope: .all,
            originFilter: [.local, .cloud]
        )
        #expect(allBoth.contains("local and cloud knowledge base"))
        let allVisible = KnowledgeQAService.systemPrompt(
            mode: .normal,
            scope: .all,
            originFilter: nil
        )
        #expect(allVisible.contains("visible knowledge base"))
        let session = KnowledgeQAService.systemPrompt(
            mode: .normal,
            scope: .session(UUID()),
            originFilter: nil
        )
        #expect(session.contains("one selected session"))
    }

    @Test
    func sourceTypeMappingFromSessionTypes() {
        #expect(KnowledgeSourceType.from(sessionType: .record) == .recording)
        #expect(KnowledgeSourceType.from(sessionType: .live) == .recording)
        #expect(KnowledgeSourceType.from(sessionType: .meetingRecord) == .meeting)
        #expect(KnowledgeSourceType.from(sessionType: .googleMeet) == .meeting)
        #expect(KnowledgeSourceType.from(sessionType: .upload) == .upload)
        #expect(KnowledgeSourceType.from(sessionType: .netVideo) == .netVideo)
        #expect(KnowledgeSourceType.from(sessionType: .dub) == .dub)
    }
}

struct KnowledgeListRowP0Tests {
    private func row(indexed: Bool) -> KnowledgeListRow {
        KnowledgeListRow(
            id: UUID(),
            title: indexed ? "Ready" : "Empty",
            sessionType: .record,
            sourceType: .recording,
            sourceOrigin: .local,
            modifiedAt: .now,
            duration: 12,
            lexicalReady: indexed,
            embeddingReady: false,
            hasTranscript: indexed
        )
    }

    @Test
    func indexedStatusIsApproximateAndQAAble() {
        let indexed = row(indexed: true)
        #expect(indexed.isIndexed)
        #expect(indexed.isQAAble)
        #expect(indexed.statusLabel == "Indexed (approx.)")
        #expect(indexed.indexStatusHelp.contains("Approximate"))
        #expect(KnowledgeListRow.p0IsSearchable(hasTranscript: true, hasUsableResult: false))
        #expect(KnowledgeListRow.p0IsSearchable(hasTranscript: false, hasUsableResult: true))
        #expect(!KnowledgeListRow.p0IsSearchable(hasTranscript: false, hasUsableResult: false))
    }

    @Test
    func unindexedRowIsNotQAAble() {
        let empty = row(indexed: false)
        #expect(!empty.isIndexed)
        #expect(!empty.isQAAble)
        #expect(empty.statusLabel == "No transcript")
        #expect(empty.indexStatusHelp.contains("Transcription is required"))
    }

    @Test
    func indexFilterIndexedHidesUnindexedRows() {
        let indexed = row(indexed: true)
        let empty = row(indexed: false)
        let listed = KnowledgeListQuery.filterRows(
            [indexed, empty],
            typeFilter: .all,
            indexFilter: .all,
            allowedOrigins: [.local, .cloud],
            query: ""
        )
        #expect(listed.map(\.id) == [indexed.id, empty.id])

        let indexedOnly = KnowledgeListQuery.filterRows(
            [indexed, empty],
            typeFilter: .all,
            indexFilter: .indexed,
            allowedOrigins: [.local, .cloud],
            query: ""
        )
        #expect(indexedOnly.map(\.id) == [indexed.id])
    }

    @Test
    func unsignedHidesCloudOriginRows() {
        let local = KnowledgeListRow(
            id: UUID(),
            title: "Local",
            sessionType: .record,
            sourceType: .recording,
            sourceOrigin: .local,
            modifiedAt: .now,
            duration: nil,
            lexicalReady: true,
            embeddingReady: false,
            hasTranscript: true
        )
        let cloud = KnowledgeListRow(
            id: UUID(),
            title: "Cloud",
            sessionType: .upload,
            sourceType: .upload,
            sourceOrigin: .cloud,
            modifiedAt: .now,
            duration: nil,
            lexicalReady: true,
            embeddingReady: false,
            hasTranscript: true
        )
        let unsigned = KnowledgeListQuery.filterRows(
            [local, cloud],
            typeFilter: .all,
            indexFilter: .all,
            allowedOrigins: [.local],
            query: ""
        )
        #expect(unsigned.map(\.id) == [local.id])
        #expect(KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: false) == [.local])
        #expect(KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: true) == [.local, .cloud])
        #expect(
            KnowledgeSourceOrigin.resolve(isCloudStorage: true, hasRemoteSessionID: false) == .cloud
        )
    }

    @Test
    func unsignedCloudFilterReturnsEmpty() {
        let local = KnowledgeListRow(
            id: UUID(), title: "Local", sessionType: .record, sourceType: .recording,
            sourceOrigin: .local, modifiedAt: .now, duration: nil,
            lexicalReady: true, embeddingReady: false, hasTranscript: true
        )
        let cloud = KnowledgeListRow(
            id: UUID(), title: "Cloud", sessionType: .upload, sourceType: .upload,
            sourceOrigin: .cloud, modifiedAt: .now, duration: nil,
            lexicalReady: true, embeddingReady: false, hasTranscript: true
        )
        let effective = KnowledgeSourceOrigin.effectiveOrigins(
            isSignedIn: false,
            uiFilter: [.cloud]
        )
        #expect(effective.isEmpty)
        let filtered = KnowledgeListQuery.filterRows(
            [local, cloud],
            typeFilter: .all,
            indexFilter: .all,
            originFilter: .cloud,
            allowedOrigins: effective,
            query: ""
        )
        #expect(filtered.isEmpty)
    }
}

struct KnowledgeQAReadyGateTests {
    @Test
    func flushesOnlyWhenPendingAndModelsReady() {
        #expect(KnowledgeQAReadyGate.shouldFlushPending(pendingQuery: "hi", missingCount: 0, isAnswering: false))
        #expect(!KnowledgeQAReadyGate.shouldFlushPending(pendingQuery: "hi", missingCount: 1, isAnswering: false))
        #expect(!KnowledgeQAReadyGate.shouldFlushPending(pendingQuery: "hi", missingCount: 0, isAnswering: true))
        #expect(!KnowledgeQAReadyGate.shouldFlushPending(pendingQuery: "  ", missingCount: 0, isAnswering: false))
        #expect(!KnowledgeQAReadyGate.shouldFlushPending(pendingQuery: nil, missingCount: 0, isAnswering: false))
    }
}

