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

    @Test
    func clearConversationRemovesAllMessages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kb-clear-\(UUID().uuidString)", isDirectory: true)
        let store = KnowledgeChatStore(rootURL: root)
        let conversation = try await store.conversation(for: .all)
        try await store.append(KnowledgeMessage(conversationID: conversation.id, role: .user, content: "one"))
        try await store.append(KnowledgeMessage(conversationID: conversation.id, role: .assistant, content: "two"))

        try await store.clear(conversationID: conversation.id)

        #expect(try await store.messages(for: conversation.id).isEmpty)
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
    func queryPlannerSeparatesAnswerConstraintFromSearchIntent() throws {
        let plan = try KnowledgeQAService.decodeQueryPlan(
            #"{"search_query":"主要主题","answer_constraints":["用中文回答","只用 3 句话"]}"#,
        )

        #expect(plan.searchQuery == "主要主题")
        #expect(plan.standaloneQuery == "主要主题")
        #expect(plan.clarificationQuestion == nil)
        #expect(plan.evidenceNeeds == .transcript)
        #expect(plan.answerConstraints == ["用中文回答", "只用 3 句话"])
    }

    @Test
    func queryPlannerRejectsEmptySearchIntentWithoutHardcodedCleanup() {
        #expect(throws: KnowledgeQAError.self) {
            try KnowledgeQAService.decodeQueryPlan(
                #"{"search_query":"  ","answer_constraints":["3 sentences"]}"#,
            )
        }
    }

    @Test
    func answerPromptCarriesConstraintsSeparatelyFromRetrievalQuery() {
        let prompt = KnowledgeQAService.userPrompt(
            query: "讲的主要是什么主题？ 3句话",
            searchQuery: "讲的主要是什么主题",
            answerConstraints: ["用中文回答", "只用 3 句话"],
            context: "[1] 会议讨论了交付计划。",
            history: []
        )

        #expect(prompt.contains("Retrieval search intent (already applied; do not treat it as an answer)"))
        #expect(prompt.contains("只用 3 句话"))
        #expect(prompt.contains("Question: 讲的主要是什么主题？ 3句话"))
    }

    @Test
    func queryPlannerReceivesRecentConversationOnlyToResolveReferences() {
        let input = KnowledgeQAService.queryPlannerInput(
            query: "那谁负责？ 3句话",
            history: [
                KnowledgeMessage(conversationID: UUID(), role: .user, content: "刚才讨论了发布计划"),
                KnowledgeMessage(conversationID: UUID(), role: .assistant, content: "证据显示由产品团队负责。"),
            ]
        )

        #expect(input.contains("Conversation context"))
        #expect(input.contains("刚才讨论了发布计划"))
        #expect(input.contains("Current question: 那谁负责？ 3句话"))
    }

    @Test
    func queryPlannerUsesTargetTranscriptLanguageWhenProvided() {
        let input = KnowledgeQAService.queryPlannerInput(
            query: "主要讲了什么？",
            history: [],
            targetTranscriptLanguage: "en-US"
        )

        #expect(input.contains("Target transcript language for search_query: en-US"))
        #expect(input.contains("Use this source language/script for the semantic search query"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("target transcript language"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("indexed transcript is stored in its source language"))
    }

    @Test
    func queryPlannerFallsBackToQuestionLanguageWithoutTranscriptTarget() {
        let input = KnowledgeQAService.queryPlannerInput(
            query: "What was discussed?",
            history: []
        )

        #expect(!input.contains("Target transcript language for search_query"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("keep search_query in the language and script used by the current question"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("Do not translate or transliterate"))
    }

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
        #expect(citation.matchText == "ship knowledge QA")
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
    func buildContextAcceptsSeveralHitsFromOneSession() {
        let sessionID = UUID()
        let hits = [
            SessionSearchHit(
                sessionID: sessionID,
                title: "One session",
                unitID: 41,
                kind: .transcriptChunk,
                start: 0,
                end: 5,
                speakerLabels: [],
                text: "First evidence",
                score: 1,
                matchSource: "bm25",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            ),
            SessionSearchHit(
                sessionID: sessionID,
                title: "One session",
                unitID: 42,
                kind: .transcriptChunk,
                start: 10,
                end: 15,
                speakerLabels: [],
                text: "Second evidence",
                score: 0.9,
                matchSource: "bm25",
                snippet: nil,
                cueIDs: [],
                hasVideo: false,
                language: nil,
                quoteSpan: nil
            ),
        ]

        let context = KnowledgeQAService.buildContext(hits: hits, maxChars: 10_000)

        #expect(context.contains("First evidence"))
        #expect(context.contains("Second evidence"))
        #expect(context.contains("time=0:00–0:05"))
        #expect(context.contains("time=0:10–0:15"))
    }

    @Test
    func catalogFallbackRendersRequestedMetadataWithoutSessionSummary() {
        let hit = SessionSearchHit(
            sessionID: UUID(),
            title: "Testing",
            unitID: 1,
            kind: .sessionCard,
            start: nil,
            end: 4,
            speakerLabels: [],
            // Simulate a stale/legacy catalog hit that still carries summary
            // text. The inventory fallback must never render it.
            text: "Testing\n## Overview\nKey Points\n* The system is being tested.",
            score: 1,
            matchSource: "catalog",
            snippet: "## Overview\nKey Points\n* The system is being tested.",
            cueIDs: [],
            hasVideo: false,
            language: "en",
            quoteSpan: nil,
            duration: 4,
            sourceOrigin: .local,
            sessionType: .record,
            sourceCreatedAt: 1_000,
            sourceModifiedAt: 2_000
        )

        let fallback = KnowledgeQAService.excerptFallback(
            query: "列出所有 session 的标题、类型、来源和时长，并按最近修改时间排序",
            hits: [hit],
            language: .chinese
        )

        #expect(fallback.contains("Testing"))
        #expect(fallback.contains("请求的 session 元数据"))
        #expect(fallback.contains("Record"))
        #expect(fallback.contains("Local"))
        #expect(fallback.contains("0:04"))
        #expect(!fallback.contains("Overview"))
        #expect(!fallback.contains("Key Points"))
        #expect(!fallback.contains("system is being tested"))
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
        #expect(session.contains("Session duration:"))
        #expect(session.contains("time="))
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

struct KnowledgeQAExecutionTests {
    @Test
    func defaultBudgetsKeepPlannerAndAnswerWithinOverallLimit() {
        let policy = KnowledgeQAExecutionPolicy.default

        #expect(policy.overall == .seconds(56))
        #expect(policy.understanding == .seconds(8))
        #expect(policy.retrieval == .seconds(8))
        #expect(policy.graphRecall == .seconds(5))
        #expect(policy.rerank == .seconds(5))
        #expect(policy.answer == .seconds(30))
    }

    @Test
    func outcomesHaveStableLogValues() {
        #expect(KnowledgeQAOutcome.completed.rawValue == "completed")
        #expect(KnowledgeQAOutcome.fallback.rawValue == "fallback")
        #expect(KnowledgeQAOutcome.timedOut.rawValue == "timedOut")
        #expect(KnowledgeQAOutcome.cancelled.rawValue == "cancelled")
        #expect(KnowledgeQAOutcome.clarification.rawValue == "clarification")
    }

    @Test
    func timeoutReturnsWithoutWaitingForNonCooperativeOperation() async throws {
        let started = ContinuousClock().now
        do {
            _ = try await KnowledgeQATimeout.run(.milliseconds(40)) {
                await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    // Simulate a provider that ignores cancellation and returns
                    // late. The timeout race must return before the provider.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        continuation.resume(returning: "late")
                    }
                }
            }
            Issue.record("expected timeout")
        } catch is KnowledgeQAError {
            // Expected timeout.
        }

        let elapsed = started.duration(to: ContinuousClock().now)
        #expect(elapsed < .milliseconds(200))
    }

    @Test
    func requestIDIsStableAcrossRequestCopies() {
        let requestID = UUID()
        let request = KnowledgeQARequest(
            queryText: "hello",
            conversationID: UUID(),
            scope: .all,
            requestID: requestID
        )
        let copy = request

        #expect(request.requestID == requestID)
        #expect(copy.requestID == requestID)
    }
}

struct KnowledgeRerankAndContextTests {
    @Test
    func rerankThresholdUsesPrimaryRelaxedAndSingleEvidenceFallback() {
        let hits = [
            reranked(unitID: 1, score: 0.26),
            reranked(unitID: 2, score: 0.24),
        ]
        #expect(KnowledgeRerankPolicy.thresholded(hits).map(\.hit.unitID) == [1])

        let relaxed = [reranked(unitID: 1, score: 0.20), reranked(unitID: 2, score: 0.18)]
        #expect(KnowledgeRerankPolicy.thresholded(relaxed).map(\.hit.unitID) == [1, 2])

        let single = [reranked(unitID: 1, score: 0.16), reranked(unitID: 2, score: 0.14)]
        #expect(KnowledgeRerankPolicy.thresholded(single).map(\.hit.unitID) == [1])
        #expect(KnowledgeRerankPolicy.thresholded([reranked(unitID: 1, score: 0.14)]).isEmpty)
    }

    @Test
    func mmrUsesStoredVectorsToAvoidNearDuplicateEvidence() {
        let candidates = [
            reranked(unitID: 1, score: 0.9, text: "first evidence"),
            reranked(unitID: 2, score: 0.88, text: "duplicate evidence"),
            reranked(unitID: 3, score: 0.7, text: "independent evidence"),
        ]
        let selected = KnowledgeMMR.select(
            candidates,
            vectors: [
                1: [1, 0, 0],
                2: [1, 0, 0],
                3: [0, 1, 0],
            ],
            limit: 2
        )

        #expect(selected.map(\.hit.unitID) == [1, 3])
    }

    @Test
    func contextAddsBoundedMetadataAndNeighborsWithoutChangingCitationAnchor() {
        let sessionID = UUID()
        let anchor = hit(sessionID: sessionID, unitID: 10, text: "anchor")
        let before = hit(sessionID: sessionID, unitID: 9, text: "before neighbor")
        let after = hit(sessionID: sessionID, unitID: 11, text: "after neighbor")
        let context = KnowledgeContextBuilder.build(
            anchors: [anchor],
            metadata: [sessionID: .init(title: "Weekly review", summary: String(repeating: "summary ", count: 100))],
            neighbors: [anchor.unitID: [after, before]],
            maxChars: 1_000
        )

        #expect(context.contains("Session title: Weekly review"))
        #expect(!context.contains("Session duration:"))
        #expect(context.contains("before neighbor"))
        #expect(context.contains("anchor"))
        #expect(context.contains("after neighbor"))
        #expect(context.count <= 1_000)
        #expect(KnowledgeQAService.citation(from: anchor).chunkIndex == 10)
    }

    @Test
    func catalogDurationIsEvidenceWithoutUsingExcerptTimestamps() {
        let sessionID = UUID()
        let anchor = hit(sessionID: sessionID, unitID: 10, text: "partial remark")
        var metadata = KnowledgeSessionContextMetadata(title: "Weekly review", summary: nil)
        metadata.duration = 754
        let withExcerpt = KnowledgeContextBuilder.build(
            anchors: [anchor],
            metadata: [sessionID: metadata],
            neighbors: [:],
            maxChars: 1_000
        )
        let catalogOnly = KnowledgeContextBuilder.build(
            anchors: [],
            metadata: [sessionID: metadata],
            neighbors: [:],
            maxChars: 1_000,
            catalogSessionIDs: [sessionID]
        )

        #expect(withExcerpt.contains("Session duration: 00:12:34"))
        #expect(withExcerpt.contains("time="))
        #expect(catalogOnly.contains("Session duration: 00:12:34"))
        #expect(!catalogOnly.contains("time="))
    }

    @Test
    func recoveryActionsDecodeWhenAbsentFromOlderMessageJSON() throws {
        let message = KnowledgeMessage(conversationID: UUID(), role: .assistant, content: "excerpt")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
        json.removeValue(forKey: "recoveryActions")
        let decoded = try JSONDecoder().decode(
            KnowledgeMessage.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.recoveryActions.isEmpty)
    }

    private func reranked(unitID: Int, score: Double, text: String = "evidence") -> KnowledgeRerankedHit {
        KnowledgeRerankedHit(hit: hit(sessionID: UUID(), unitID: unitID, text: text), score: score)
    }

    private func hit(sessionID: UUID, unitID: Int, text: String) -> SessionSearchHit {
        SessionSearchHit(
            sessionID: sessionID,
            title: "Session",
            unitID: unitID,
            kind: .transcriptChunk,
            start: Double(unitID),
            end: Double(unitID + 1),
            speakerLabels: [],
            text: text,
            score: 1,
            matchSource: "test",
            snippet: nil,
            cueIDs: [],
            hasVideo: false,
            language: "en",
            quoteSpan: nil
        )
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

struct KnowledgeAnswerLanguageTests {
    @Test
    func detectsChineseQuestionAndPinsPromptLanguage() {
        let question = "这个 session 的主要主题是什么？"

        #expect(KnowledgeAnswerLanguage.detect(from: question) == .chinese)

        let prompt = KnowledgeQAService.systemPrompt(
            mode: .normal,
            scope: .all,
            originFilter: nil,
            answerLanguage: .chinese
        )
        #expect(prompt.contains("Chinese (中文)"))
        #expect(prompt.contains("Never switch to English"))
    }

    @Test
    func noEvidenceFallbackUsesQuestionLanguage() {
        let message = KnowledgeQAService.insufficientEvidenceMessage(
            scope: .session(UUID()),
            language: .chinese
        )

        #expect(message.contains("没有找到足够的证据"))
        #expect(!message.contains("I could not"))
    }
}

struct KnowledgeTranscriptNavigationTests {
    @Test
    func citationTimeSelectsOverlappingTranscriptSegment() {
        let segments = [
            TranscriptionSegment(text: "开场", start: 0, end: 4),
            TranscriptionSegment(text: "主要讨论数学", start: 10, end: 18),
            TranscriptionSegment(text: "结尾", start: 20, end: 24),
        ]
        let target = KnowledgeTranscriptTarget(startTime: 12, endTime: 14, matchText: "数学")

        #expect(KnowledgeTranscriptNavigation.segmentIndex(for: target, in: segments) == 1)
    }

    @Test
    func citationTimeFallsBackToNearestSegment() {
        let segments = [
            TranscriptionSegment(text: "first", start: 0, end: 2),
            TranscriptionSegment(text: "second", start: 10, end: 12),
        ]
        let target = KnowledgeTranscriptTarget(startTime: 7, endTime: 8, matchText: "second")

        #expect(KnowledgeTranscriptNavigation.segmentIndex(for: target, in: segments) == 1)
    }
}

struct KnowledgeQueryPlanDecodingTests {
    @Test
    func standaloneQueryFallsBackToSearchQueryAndClarificationIsOptional() throws {
        let plan = try KnowledgeQAService.decodeQueryPlan(
            #"{"search_query":"张三 方案","answer_constraints":[]}"#
        )
        #expect(plan.standaloneQuery == "张三 方案")
        #expect(plan.searchQuery == "张三 方案")
        #expect(plan.clarificationQuestion == nil)
        #expect(plan.evidenceNeeds == .transcript)
    }

    @Test
    func evidenceNeedsSelectsCatalogWithoutALanguageKeyword() throws {
        let catalog = try KnowledgeQAService.decodeQueryPlan(
            #"{"search_query":"此视频","answer_constraints":[],"evidence_needs":"catalog"}"#
        )
        let both = try KnowledgeQAService.decodeQueryPlan(
            #"{"search_query":"此视频 内容","answer_constraints":[],"evidence_needs":"both"}"#
        )
        let unknown = try KnowledgeQAService.decodeQueryPlan(
            #"{"search_query":"此视频","answer_constraints":[],"evidence_needs":"metadata"}"#
        )

        #expect(catalog.evidenceNeeds == .catalog)
        #expect(both.evidenceNeeds == .both)
        #expect(unknown.evidenceNeeds == .transcript)
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("evidence_needs"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("recording or session itself"))
    }

    @Test
    func catalogSessionsFollowScopeOrPriorCitations() {
        let selected = UUID()
        let other = UUID()
        let hit = SessionSearchHit(
            sessionID: other,
            title: "Other",
            unitID: 1,
            kind: .transcriptChunk,
            start: 1,
            end: 2,
            speakerLabels: [],
            text: "excerpt",
            score: 1,
            matchSource: "test",
            snippet: "excerpt",
            cueIDs: [],
            hasVideo: false,
            language: "en",
            quoteSpan: nil
        )
        let history = [
            KnowledgeMessage(
                conversationID: UUID(),
                role: .assistant,
                content: "previous",
                citations: [
                    KnowledgeSourceRef(
                        sourceID: other.uuidString,
                        sourceType: "sessionTranscript",
                        title: "Other",
                        uri: nil,
                        page: nil,
                        startTime: 1,
                        endTime: 2,
                        parentID: nil,
                        chunkIndex: 1,
                        language: nil,
                        speaker: nil,
                        snippet: "excerpt",
                        matchText: nil
                    )
                ]
            )
        ]

        #expect(KnowledgeQAService.catalogSessionIDs(hits: [hit], scope: .session(selected), history: history) == [selected])
        #expect(KnowledgeQAService.catalogSessionIDs(hits: [hit], scope: .all, history: history) == [other])
        #expect(KnowledgeQAService.catalogSessionIDs(hits: [], scope: .all, history: history) == [other])
    }

    @Test
    func clarificationQuestionIsPreserved() throws {
        let plan = try KnowledgeQAService.decodeQueryPlan(
            #"{"standalone_query":"他为什么这么做？","search_query":"他为什么这么做？","answer_constraints":[],"clarification_question":"你指的是张三还是李四？"}"#
        )
        #expect(plan.needsClarification)
        #expect(plan.clarificationQuestion == "你指的是张三还是李四？")
    }

    @Test
    func followUpPlanCanResolvePronounToNamedPerson() throws {
        let plan = try KnowledgeQAService.decodeQueryPlan(
            #"{"standalone_query":"张三为什么提出该方案？","search_query":"张三 方案 原因","answer_constraints":[]}"#
        )
        #expect(plan.standaloneQuery.contains("张三"))
        #expect(plan.searchQuery.contains("张三"))
    }

    @Test
    func plannerPromptRequiresHistoryAwareRewriteWithoutGuessing() {
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("standalone_query"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("clarification_question"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("Do not treat prior assistant answers as knowledge-base facts"))
        #expect(KnowledgeQAService.queryPlannerPrompt.contains("do not guess"))
    }

    @Test
    func plannerInputKeepsOnlyTheMostRecentSixMessages() {
        let conversationID = UUID()
        var history: [KnowledgeMessage] = []
        for index in 1...7 {
            history.append(
                KnowledgeMessage(
                    conversationID: conversationID,
                    role: index.isMultiple(of: 2) ? .assistant : .user,
                    content: "message-\(index)"
                )
            )
        }
        let input = KnowledgeQAService.queryPlannerInput(
            query: "他为什么这么做？",
            history: history
        )
        #expect(!input.contains("message-1"))
        #expect(input.contains("message-2"))
        #expect(input.contains("message-7"))
        #expect(input.contains("Current question: 他为什么这么做？"))
    }
}

struct KnowledgeRetrievalServiceTests {
    @Test
    func waitsForSlowGraphAndKeepsGraphOnlyHit() async throws {
        let hybridHit = testHit(unitID: 1, text: "hybrid evidence about delivery")
        let graphHit = testHit(unitID: 2, text: "graph-only evidence about the same plan")
        let graphCalls = PlannerCallBox()
        let service = KnowledgeRetrievalService(
            executionPolicy: KnowledgeQAExecutionPolicy(
                retrieval: .milliseconds(400),
                graphRecall: .milliseconds(200),
                rerank: .milliseconds(50)
            ),
            dependencies: KnowledgeQAExecutionDependencies(
                hybridRecall: { _, _ in [hybridHit] },
                graphRecall: { _, _ in
                    graphCalls.count += 1
                    try await Task.sleep(for: .milliseconds(40))
                    return [graphHit]
                },
                reranker: { _, chunks in chunks.map { _ in 0.9 } }
            )
        )
        let result = try await service.search(agentRequest(query: "方案"))
        #expect(graphCalls.count == 1)
        #expect(result.diagnostics.graphAttempted)
        #expect(result.diagnostics.graphStatus == .used)
        #expect(Set(result.hits.map(\.unitID)) == [1, 2])
        #expect(result.diagnostics.hybridHitCount == 1)
        #expect(result.diagnostics.graphHitCount == 1)
        #expect(result.diagnostics.rerankerStatus == .used)
    }

    @Test
    func deduplicatesSharedUnitIDsPreferringHybrid() async throws {
        let sessionID = UUID()
        let hybrid = testHit(sessionID: sessionID, unitID: 7, text: "hybrid copy")
        let graph = testHit(sessionID: sessionID, unitID: 7, text: "graph copy")
        let service = KnowledgeRetrievalService(
            dependencies: KnowledgeQAExecutionDependencies(
                hybridRecall: { _, _ in [hybrid] },
                graphRecall: { _, _ in [graph] },
                reranker: { _, chunks in chunks.map { _ in 0.9 } }
            )
        )
        let result = try await service.search(agentRequest(query: "copy"))
        #expect(result.hits.map(\.unitID) == [7])
        #expect(result.hits.first?.text == "hybrid copy")
        #expect(result.diagnostics.candidateCount == 1)
    }

    @Test
    func graphFailureStillReturnsHybridEvidence() async throws {
        let hybridHit = testHit(unitID: 3, text: "hybrid still available")
        let service = KnowledgeRetrievalService(
            executionPolicy: KnowledgeQAExecutionPolicy(
                retrieval: .milliseconds(300),
                graphRecall: .milliseconds(40),
                rerank: .milliseconds(50)
            ),
            dependencies: KnowledgeQAExecutionDependencies(
                hybridRecall: { _, _ in [hybridHit] },
                graphRecall: { _, _ in
                    throw KnowledgeQAError.timeout
                },
                reranker: { _, chunks in chunks.map { _ in 0.9 } }
            )
        )
        let result = try await service.search(agentRequest(query: "hybrid"))
        #expect(result.hits.map(\.unitID) == [3])
        #expect(result.diagnostics.graphAttempted)
        #expect(result.diagnostics.graphStatus == .timeout)
    }

    @Test
    func graphDisabledDoesNotAttemptRecall() async throws {
        let hybridHit = testHit(unitID: 4, text: "hybrid only")
        let service = KnowledgeRetrievalService(
            dependencies: KnowledgeQAExecutionDependencies(
                hybridRecall: { _, _ in [hybridHit] },
                reranker: { _, chunks in chunks.map { _ in 0.9 } }
            )
        )
        let result = try await service.search(agentRequest(query: "topic"))
        #expect(result.hits.map(\.unitID) == [4])
        #expect(!result.diagnostics.graphAttempted)
        #expect(result.diagnostics.graphStatus == .disabled || result.diagnostics.graphStatus == .unavailable)
    }

    @Test
    func visibleFilterIncludesCloudOwner() async {
        let service = KnowledgeRetrievalService()
        let filter = await service.makeVisibleFilter(scope: .all, originFilter: nil)
        let owner = await MainActor.run { AccountService.shared.userID?.uuidString }
        #expect(filter.cloudOwnerUserID == owner)
        #expect(filter.limit == 30)
        #expect(filter.sourceOrigins != nil)
    }

    @Test
    func agentCatalogQueriesDoNotUseCatalogHeuristic() async throws {
        let hit = testHit(unitID: 9, text: "how many sessions were listed in the transcript")
        let service = KnowledgeRetrievalService(
            dependencies: KnowledgeQAExecutionDependencies(
                hybridRecall: { query, _ in
                    #expect(query.contains("how many sessions"))
                    return [hit]
                },
                graphRecall: { _, _ in [] },
                reranker: { _, chunks in chunks.map { _ in 0.9 } }
            )
        )
        let result = try await service.search(
            KnowledgeRetrievalRequest(
                query: "how many sessions mentioned budget",
                scope: .all,
                originFilter: nil,
                resultLimit: 8,
                requestID: UUID(),
                includeCatalog: false,
                retrievalPath: .agent
            )
        )
        #expect(result.hits.map(\.unitID) == [9])
        #expect(result.hits.first?.matchSource != "catalog")
    }

    private func agentRequest(query: String) -> KnowledgeRetrievalRequest {
        KnowledgeRetrievalRequest(
            query: query,
            scope: .all,
            originFilter: nil,
            resultLimit: 8,
            requestID: UUID(),
            includeCatalog: false,
            retrievalPath: .agent
        )
    }

    private func testHit(
        sessionID: UUID = UUID(),
        unitID: Int,
        text: String
    ) -> SessionSearchHit {
        SessionSearchHit(
            sessionID: sessionID,
            title: "Session",
            unitID: unitID,
            kind: .transcriptChunk,
            start: Double(unitID),
            end: Double(unitID + 1),
            speakerLabels: ["Alice"],
            text: text,
            score: 1,
            matchSource: "test",
            snippet: text,
            cueIDs: [],
            hasVideo: false,
            language: "en",
            quoteSpan: nil
        )
    }
}

struct KnowledgeQAClarificationAndFallbackTests {
    @Test
    func plannerClarificationSkipsRetrievalAndDoesNotFail() async {
        let box = PlannerCallBox()
        let hybridCalls = PlannerCallBox()
        var service = KnowledgeQAService()
        service.useAgentRuntime = false
        service.skillsProvider = { [] }
        service.dependencies = KnowledgeQAExecutionDependencies(
            planner: { query, _, _, _ in
                box.count += 1
                return KnowledgeQueryPlan(
                    standaloneQuery: query,
                    searchQuery: query,
                    answerConstraints: [],
                    clarificationQuestion: "你指的是张三还是李四？"
                )
            },
            hybridRecall: { _, _ in
                hybridCalls.count += 1
                return []
            }
        )
        let events = await collect(
            service.answer(
                KnowledgeQARequest(queryText: "他为什么这么做？", conversationID: UUID(), scope: .all)
            )
        )
        #expect(box.count == 1)
        #expect(hybridCalls.count == 0)
        #expect(events.contains { if case .clarification("你指的是张三还是李四？") = $0 { return true }; return false })
        #expect(!events.contains { if case .failed = $0 { return true }; return false })
        #expect(!events.contains { if case .citations = $0 { return true }; return false })
    }

    @Test
    func explicitLegacyRuntimePlansOnlyOnce() async {
        let box = PlannerCallBox()
        var service = KnowledgeQAService()
        service.useAgentRuntime = false
        service.skillsProvider = { [] }
        service.dependencies = KnowledgeQAExecutionDependencies(
            planner: { query, history, _, _ in
                box.count += 1
                #expect(history.contains(where: { $0.content.contains("张三提出了什么方案") }))
                return KnowledgeQueryPlan(
                    standaloneQuery: "张三为什么提出该方案？",
                    searchQuery: "张三 方案 原因",
                    answerConstraints: [],
                    clarificationQuestion: nil
                )
            },
            hybridRecall: { query, _ in
                #expect(query == "张三 方案 原因")
                return []
            },
            graphRecall: { _, _ in [] },
            reranker: { _, chunks in chunks.map { _ in 0.9 } }
        )
        let conversationID = UUID()
        let events = await collect(
            service.answer(
                KnowledgeQARequest(
                    queryText: "他为什么这么做？",
                    conversationID: conversationID,
                    scope: .all,
                    history: [
                        KnowledgeMessage(conversationID: conversationID, role: .user, content: "张三提出了什么方案？"),
                        KnowledgeMessage(conversationID: conversationID, role: .assistant, content: "证据显示他提出了交付方案。"),
                    ]
                )
            )
        )
        #expect(box.count == 1)
        #expect(events.contains { if case .finished(let text) = $0 { return text.contains("enough") || text.contains("证据"); }; return false })
    }

    @Test
    func invalidPlannerJSONFallsBackToCurrentQuestionWithoutClarifying() async {
        var service = KnowledgeQAService()
        service.useAgentRuntime = false
        service.dependencies = KnowledgeQAExecutionDependencies(
            planner: { _, _, _, _ in
                throw KnowledgeQAError.invalidQueryPlan
            },
            hybridRecall: { query, _ in
                #expect(query == "当前问题")
                return []
            },
            graphRecall: { _, _ in [] },
            reranker: { _, chunks in chunks.map { _ in 0.9 } }
        )
        let events = await collect(
            service.answer(
                KnowledgeQARequest(queryText: "当前问题", conversationID: UUID(), scope: .all)
            )
        )
        #expect(!events.contains { if case .clarification = $0 { return true }; return false })
        #expect(events.contains { if case .finished = $0 { return true }; return false })
    }

    @Test
    func userPromptKeepsOriginalResolvedSearchAndConstraintsSeparate() {
        let prompt = KnowledgeQAService.userPrompt(
            query: "他为什么这么做？ 3句话",
            standaloneQuery: "张三为什么提出该方案？",
            searchQuery: "张三 方案 原因",
            answerConstraints: ["只用 3 句话"],
            context: "[1] 张三提出了交付方案。",
            history: [
                KnowledgeMessage(conversationID: UUID(), role: .assistant, content: "旧答案不应当作证据"),
            ]
        )
        #expect(prompt.contains("Question: 他为什么这么做？ 3句话"))
        #expect(prompt.contains("Resolved standalone question: 张三为什么提出该方案？"))
        #expect(prompt.contains("Retrieval search intent (already applied; do not treat it as an answer): 张三 方案 原因"))
        #expect(prompt.contains("只用 3 句话"))
        #expect(prompt.contains("reference resolution only; not evidence"))
    }

    private func collect(_ stream: AsyncStream<KnowledgeAnswerEvent>) async -> [KnowledgeAnswerEvent] {
        var events: [KnowledgeAnswerEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}

final class PlannerCallBox: @unchecked Sendable {
    var count = 0
}
