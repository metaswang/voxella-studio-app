import Foundation
import Testing
@testable import PalmierPro

struct KnowledgeEvidenceWorkspaceTests {
    @Test func mediaLengthAndSpokenPositionHaveSeparateProvenance() {
        let source = fixture(duration: 1_800, segments: [.init(text: "最后一句", start: 1_420, end: 1_440)])
        let facts = KnowledgeMediaFacts.from(source)
        #expect(facts.mediaDuration == 1_800)
        #expect(facts.lastSpokenEnd == 1_440)
        var unknown = source
        unknown.durationHint = nil
        #expect(KnowledgeMediaFacts.from(unknown).mediaDuration == nil)
        #expect(KnowledgeMediaFacts.from(unknown).lastSpokenEnd == 1_440)
        unknown.durationHint = .nan
        #expect(KnowledgeMediaFacts.from(unknown).mediaDuration == nil)
    }

    @Test func nativeSchemasCarryArrayItemsAndNestedCells() throws {
        let schema = KnowledgeToolDefinition.analysisUpdate.schema.inputSchema
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect((properties["session_ids"]?["items"] as? [String: String])?["type"] == "string")
        #expect((properties["cells"]?["items"] as? [String: Any])?["type"] as? String == "object")
        #expect(KnowledgeToolRegistry.allTools.allSatisfy { !$0.nativeName.contains(".") })
        #expect(Set(KnowledgeToolRegistry.allTools.map(\.nativeName)).count == KnowledgeToolRegistry.allTools.count)
    }

    @Test func malformedParametersRecoverWithoutBroadeningScope() async throws {
        let source = fixture()
        let executor = makeExecutor([source])
        for input in ["{", "[]", "{\"query\":false}", "{\"query\":\"x\",\"session_ids\":[\"bad\"]}",
                      KnowledgeJSON.encode(["query": "x", "session_ids": [UUID().uuidString]])] {
            #expect(try await executor.executeNative(name: "knowledge_search", inputJSON: input).isError)
        }
        #expect(try await executor.executeNative(name: "delete_session", inputJSON: "{}").isError)
        #expect(try await executor.executeNative(name: "session_list", inputJSON: "{\"date_from\":\"last week\"}").isError)
        #expect(try await executor.executeNative(name: "session_get_segments", inputJSON: KnowledgeJSON.encode([
            "session_id": source.id.uuidString, "start": 30, "end": 10])).isError)
    }

    @Test func inventoryPagesAndAggregateUseTheWholePopulation() async throws {
        let sources = (0..<63).map { fixture(title: "Meeting \($0)", duration: $0 < 60 ? 10 : nil) }
        let executor = makeExecutor(sources)
        let first = try await executor.executeNative(name: "session_list", inputJSON: "{\"limit\":20}")
        let json = try LLMJSONValue.parseObject(first.json)
        #expect(json["total_count"] == .number(63))
        #expect(json["returned_count"] == .number(20))
        #expect(json["complete"] == .bool(false))
        #expect(json["next_cursor"] == .number(20))
        let last = try await executor.executeNative(name: "session_list", inputJSON: "{\"limit\":20,\"cursor\":60}")
        #expect(try LLMJSONValue.parseObject(last.json)["returned_count"] == .number(3))
        let aggregated = try await executor.executeNative(name: "session_aggregate", inputJSON: "{\"limit\":1,\"group_by\":\"type\"}")
        guard case .object(let aggregate) = try LLMJSONValue.parseObject(aggregated.json)["aggregate"] else { Issue.record("Missing aggregate"); return }
        #expect(aggregate["count"] == .number(63))
        #expect(aggregate["media_duration_sum_sec"] == .number(600))
        #expect(aggregate["duration_unknown_count"] == .number(3))
        #expect(aggregate["semantic_count"] == .bool(false))
        #expect(aggregated.citations.count >= 1)
    }

    @Test func directReadPagesContainOriginalTextAndDoNotSearch() async throws {
        let source = fixture(segments: (0..<205).map { .init(text: "句子 \($0)", start: Double($0), end: Double($0 + 1), speaker: "张三") })
        let executor = makeExecutor([source])
        let first = try await executor.executeNative(name: "session_get_segments", inputJSON: KnowledgeJSON.encode(["session_id": source.id.uuidString]))
        let json = try LLMJSONValue.parseObject(first.json)
        #expect(json["total_count"] == .number(205))
        #expect(json["returned_count"] == .number(80))
        #expect(json["next_cursor"] == .number(80))
        #expect(first.json.contains("句子 79"))
        let last = try await executor.executeNative(name: "session_get_segments", inputJSON: KnowledgeJSON.encode([
            "session_id": source.id.uuidString, "cursor": 200]))
        #expect(try LLMJSONValue.parseObject(last.json)["complete"] == .bool(true))
        #expect(last.citations.contains { $0.startTime == 204 && $0.endTime == 205 })
    }

    @Test func summariesAreCompletePagedObservationsAndUnavailableRowsRemain() async throws {
        let a = fixture(summary: String(repeating: "摘要", count: 5_000))
        let b = fixture(summary: nil)
        let executor = makeExecutor([a, b])
        let result = try await executor.executeNative(name: "knowledge_compare_sessions", inputJSON: KnowledgeJSON.encode([
            "session_ids": [a.id.uuidString, b.id.uuidString]]))
        #expect(!result.isError)
        let json = try LLMJSONValue.parseObject(result.json)
        guard case .array(let rows) = json["comparisons"] else { Issue.record("Missing comparison rows"); return }
        #expect(rows.count == 2)
        #expect(result.json.contains("unavailable"))
        #expect(result.json.contains("next_cursor"))
        #expect(result.json.contains("summary_markdown"))
    }

    @Test func analysisDistinguishesNotFoundFromAbsenceAndRejectsForeignEvidence() async throws {
        let a = fixture(), b = fixture()
        let workspace = KnowledgeEvidenceWorkspace(snapshot: snapshot([a, b]))
        let executor = KnowledgeToolExecutor(scope: .all, originFilter: nil, retrievalService: .init(), workspace: workspace)
        let metadata = try await executor.executeNative(name: "knowledge_get_session_metadata", inputJSON: KnowledgeJSON.encode(["session_id": a.id.uuidString]))
        guard case .array(let refs) = try LLMJSONValue.parseObject(metadata.json)["citations"],
              case .object(let row) = refs.first, case .string(let evidenceID) = row["evidence_id"] else { Issue.record("Missing stable evidence ID"); return }
        let initial = try await executor.executeNative(name: "analysis_update", inputJSON: KnowledgeJSON.encode([
            "session_ids": [a.id.uuidString, b.id.uuidString], "dimensions": ["理由", "异议"]]))
        #expect(initial.json.contains("unchecked"))
        let bad = try await executor.executeNative(name: "analysis_update", inputJSON: KnowledgeJSON.encode(["cells": [[
            "session_id": b.id.uuidString, "dimension": "异议", "status": "absent", "finding": "没有异议", "evidence_ids": [evidenceID]]]]))
        #expect(bad.isError)
        let notFound = try await executor.executeNative(name: "analysis_update", inputJSON: KnowledgeJSON.encode(["cells": [[
            "session_id": a.id.uuidString, "dimension": "理由", "status": "not_found", "finding": "暂未找到", "evidence_ids": []]]]))
        #expect(!notFound.isError)
        #expect(notFound.json.contains("not_found"))
        #expect(notFound.json.contains(b.id.uuidString))
    }

    @Test func unchangedSourceVersionsAreStableAcrossIndependentEncoders() {
        let source = fixture(summary: "Stable evidence", segments: [
            .init(text: "A conditional decision", start: 1, end: 2, speaker: "A"),
            .init(text: "A later revision", start: 4, end: 5, speaker: "B")])
        let versions = Set((0..<100).map { _ in KnowledgeScopeSnapshot.generation(source) })
        #expect(versions.count == 1)
    }

    @Test func sourceChangesInvalidateCacheNamespaceAndEvidenceIDs() async throws {
        var source = fixture(summary: "旧决定")
        let before = snapshot([source])
        source.summaryMarkdown = "后来修正"
        let after = snapshot([source])
        #expect(before.cacheNamespace != after.cacheNamespace)
        let beforeExecutor = makeExecutor(before.sessions)
        let afterExecutor = makeExecutor(after.sessions)
        let args = KnowledgeJSON.encode(["session_id": source.id.uuidString])
        let a = try await beforeExecutor.executeNative(name: "session_get_summary", inputJSON: args)
        let b = try await afterExecutor.executeNative(name: "session_get_summary", inputJSON: args)
        #expect(a.json != b.json)
        var differentOwner = after
        differentOwner = .init(scope: after.scope, ownerID: UUID(), sessions: after.sessions, generations: after.generations, isLive: false)
        #expect(differentOwner.cacheNamespace != after.cacheNamespace)
    }

    @Test func payloadCanBeRecoveredByItsActualHandle() async throws {
        let executor = makeExecutor([fixture()])
        let result = try await executor.executeNative(name: "session_list", inputJSON: "{}")
        guard case .string(let handle) = try LLMJSONValue.parseObject(result.json)["payload_ref"] else { Issue.record("Missing payload handle"); return }
        let saved = try await executor.executeNative(name: "read_payload", inputJSON: KnowledgeJSON.encode(["payload_ref": handle]))
        #expect(!saved.isError)
        #expect(saved.json.contains("total_count"))
    }

    @Test func largePriorEvidenceStaysBoundedAndRecoverable() async throws {
        let source = fixture()
        let workspace = KnowledgeEvidenceWorkspace(snapshot: snapshot([source]))
        for index in 0..<30 {
            let ref = KnowledgeSourceRef(sourceID: source.id.uuidString, sourceType: "transcript", title: source.title,
                uri: nil, page: nil, startTime: Double(index), endTime: Double(index + 1), parentID: nil,
                chunkIndex: index, language: nil, speaker: nil, snippet: String(repeating: "证据", count: 8_000),
                matchText: String(repeating: "完整匹配", count: 4_000))
            _ = await workspace.record(KnowledgeJSON.encode(["citations": [KnowledgeJSON.citation(ref)]]))
        }
        #expect(await workspace.priorEvidenceIndex().count <= 16_000)
        #expect(await workspace.sourceEvidence(source.id).count <= 16_000)
        let memory = await workspace.memory()
        #expect(memory.references.count == 30 && memory.payloads.count == 30)
    }

    @Test func sourceWorkerCannotRecoverAnotherSourcesPayload() async throws {
        let a = fixture(summary: "A decision"), b = fixture(summary: "B confidential context")
        let workspace = KnowledgeEvidenceWorkspace(snapshot: snapshot([a, b]))
        let main = KnowledgeToolExecutor(scope: .all, originFilter: nil, retrievalService: .init(), workspace: workspace)
        let worker = KnowledgeToolExecutor(scope: .session(a.id), originFilter: nil, retrievalService: .init(), workspace: workspace)
        let observation = try await main.executeNative(name: "session_get_summary", inputJSON: KnowledgeJSON.encode(["session_id": b.id.uuidString]))
        guard case .string(let handle) = try LLMJSONValue.parseObject(observation.json)["payload_ref"] else { Issue.record("Missing handle"); return }
        #expect(try await worker.executeNative(name: "read_payload", inputJSON: KnowledgeJSON.encode(["payload_ref": handle])).isError)
        #expect(!(try await main.executeNative(name: "read_payload", inputJSON: KnowledgeJSON.encode(["payload_ref": handle])).isError))
    }

    @Test func followUpRestoresEvidenceAndAnalysisWithoutProviderState() async throws {
        let source = fixture(summary: "Final decision")
        let workspace = KnowledgeEvidenceWorkspace(snapshot: snapshot([source]))
        let executor = KnowledgeToolExecutor(scope: .all, originFilter: nil, retrievalService: .init(), workspace: workspace)
        _ = try await executor.executeNative(name: "session_get_summary", inputJSON: KnowledgeJSON.encode(["session_id": source.id.uuidString]))
        _ = try await workspace.updateAnalysis(KnowledgeJSON.encode(["session_ids": [source.id.uuidString], "dimensions": ["decision", "risk"]]))
        let restored = KnowledgeEvidenceWorkspace(snapshot: snapshot([source]))
        await restored.restore(await workspace.memory())
        let originalReferences = await workspace.citations()
        #expect(await restored.citations() == originalReferences)
        let initial = await restored.priorEvidenceIndex()
        #expect(initial.contains("Final decision") && initial.contains("decision") && initial.contains("unchecked"))
        #expect(initial.contains("evidence_id") && initial.contains("saved_payload_refs"))
    }

    @Test func providerSelectionPinsTheFirstCommittedNativeRoute() async throws {
        let profile = LLMProviderProfile(provider: .openAI, baseURL: "https://example.invalid/v1", model: "model-a")
        let configurations = ["model-a", "model-b"].map { name in
            LLMRuntimeConfiguration(profile: profile, modelIdentifier: name, modelName: name,
                                    endpoint: URL(string: "https://example.invalid/v1/responses")!, apiKey: "")
        }
        let selection = KnowledgeProviderSelection()
        await selection.noteCandidate("model-a")
        #expect(await selection.configurations(from: configurations).count == 2)
        await selection.noteCandidate("model-b") // failover before any event
        await selection.commit()
        await selection.noteCandidate("model-a")
        await selection.commit()
        #expect(await selection.configurations(from: configurations).map(\.modelIdentifier) == ["model-b"])
    }

    @Test func signedThinkingAndNativeCallIDsRetainOrder() {
        var turn = KnowledgeNativeTurn()
        turn.consume(.thinkingDelta("private"))
        turn.consume(.thinkingSignature("sig"))
        turn.consume(.textDelta("已确认"))
        turn.consume(.toolUseComplete(id: "call-array", name: "session_search_segments", inputJSON: "{\"session_ids\":[\"a\",\"b\"]}"))
        turn.consume(.reasoningComplete(itemID: "r1", summary: "", encryptedContent: "encrypted", model: .terra))
        #expect(turn.blocks.count == 4)
        if case .thinking(let text, let signature) = turn.blocks[0] { #expect(text == "private"); #expect(signature == "sig") }
        else { Issue.record("Lost signed thinking") }
        #expect(turn.calls.first?.id == "call-array")
        #expect(turn.calls.first?.inputJSON.contains("[\"a\",\"b\"]") == true)
    }

    @Test func workerPoolHasRealJobsAndOneSharedRequestBudget() async throws {
        let pool = KnowledgeWorkerPool()
        let first = await pool.start { .error("worker failed") }
        let second = await pool.start { KnowledgeToolObservation(json: "{\"findings\":[]}", isError: false, citations: []) }
        let third = await pool.start { .error("must not start") }
        #expect(!first.isError && !second.isError)
        #expect(third.isError)
        guard case .string(let id) = try LLMJSONValue.parseObject(first.json)["job_id"] else { Issue.record("No real job"); return }
        #expect(await pool.result(id: id).isError)
        let budget = KnowledgeRunBudget()
        for _ in 0..<16 { try await budget.reserve(messages: [], system: "") }
        await #expect(throws: KnowledgeNativeRunError.self) { try await budget.reserve(messages: [], system: "") }
        await pool.cancelAll()
    }

    @Test func fusionAndCoverageRetainRelevantSourcesBeyondEightHits() {
        let a = UUID(), b = UUID()
        let hybrid = (0..<30).map { hit(session: a, unit: $0) }
        let graph = [hit(session: b, unit: 99)]
        #expect(KnowledgeRetrievalService.fuse(hybrid: hybrid, graph: graph, limit: 10).contains { $0.unitID == 99 })
        let candidates = (hybrid + graph).map { KnowledgeRerankedHit(hit: $0, score: 0.9) }
        let selected = KnowledgeMMR.select(candidates, vectors: [:], limit: 12, coverSources: true)
        #expect(selected.count == 12)
        #expect(Set(selected.map(\.hit.sessionID)).count == 2)
    }

    private func hit(session: UUID, unit: Int) -> SessionSearchHit {
        .init(sessionID: session, title: "Source", unitID: unit, kind: .transcriptChunk, start: Double(unit), end: Double(unit + 1),
              speakerLabels: [], text: "Original \(unit)", score: 1, matchSource: "test", snippet: nil, cueIDs: [],
              hasVideo: false, language: nil, quoteSpan: nil)
    }

    func fixture(title: String = "会议", duration: Double? = nil, summary: String? = "发布计划摘要",
                 segments: [TranscriptionSegment]? = nil) -> WorkbenchSession {
        .init(id: UUID(), title: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
              modifiedAt: Date(timeIntervalSince1970: 1_700_000_100), state: .completed, source: .media, sessionType: .upload,
              transcriptionID: nil, dubID: nil, sourceURL: nil, outputURL: nil, durationHint: duration,
              transcript: segments.map { .init(text: $0.map(\.text).joined(), language: "zh", words: [], segments: $0) },
              subtitleTrack: nil, translationTracks: [], selectedTranslationLanguageCode: nil,
              summaryMarkdown: summary, summaryTemplateID: nil, summaryTemplateName: nil, summaryState: nil,
              summaryErrorMessage: nil, sessionTag: nil, dubTranscript: nil, dubSubtitleTrack: nil, dubSegments: [])
    }

    func snapshot(_ sources: [WorkbenchSession]) -> KnowledgeScopeSnapshot {
        .init(scope: .all, ownerID: nil, sessions: sources,
              generations: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, KnowledgeScopeSnapshot.generation($0)) }), isLive: false)
    }

    func makeExecutor(_ sources: [WorkbenchSession]) -> KnowledgeToolExecutor {
        .init(scope: .all, originFilter: nil, retrievalService: .init(), workspace: KnowledgeEvidenceWorkspace(snapshot: snapshot(sources)))
    }
}

struct KnowledgeNativeRuntimeTests {
    @Test func firstRoundFactsStreamWithoutPlannerOrSearch() async throws {
        let fixtures = KnowledgeEvidenceWorkspaceTests()
        let source = fixtures.fixture(duration: 1_800, segments: [.init(text: "尾部口播", start: 1_430, end: 1_440)])
        let snapshot = fixtures.snapshot([source])
        let client = KnowledgeReplayClient { index, tools, messages in
            #expect(index == 0)
            #expect(tools.contains { $0.name == "knowledge_search" })
            if case .content(.text(let input)) = messages.last?.content.first {
                #expect(input.contains("1800")); #expect(input.contains("1440"))
            } else { Issue.record("Missing scope facts") }
            return [.textDelta("视频总长 30 分钟"), .textDelta("，最后口播在 24 分钟。[1]"), .messageStop(stopReason: .endTurn)]
        }
        var service = KnowledgeQAService()
        service.dependencies.planner = { _, _, _, _ in Issue.record("Native path must not plan independently"); return .fallback(for: "") }
        service.agentClientFactory = { client }
        service.scopeSnapshotProvider = { snapshot }
        service.skillsProvider = { [] }
        let request = KnowledgeQARequest(queryText: "这个视频多长？", conversationID: UUID(), scope: .all)
        var deltas: [String] = [], terminals = 0
        for await event in service.answer(request) {
            if case .delta(let text) = event { deltas.append(text) }
            if case .finished = event { terminals += 1 }
            if case .failed(let message) = event { Issue.record("\(message)") }
        }
        #expect(deltas.count == 2)
        #expect(terminals == 1)
    }

    @Test func providerOutputLimitRetainsPartialTextButDoesNotFinishSuccessfully() async throws {
        let fixtures = KnowledgeEvidenceWorkspaceTests()
        let snapshot = fixtures.snapshot([fixtures.fixture()])
        let client = KnowledgeReplayClient { _, _, _ in
            [.textDelta("Already confirmed partial evidence."), .messageStop(stopReason: .maxTokens)]
        }
        var service = KnowledgeQAService()
        service.dependencies.planner = { _, _, _, _ in .fallback(for: "") }
        service.agentClientFactory = { client }
        service.scopeSnapshotProvider = { snapshot }
        service.skillsProvider = { [] }
        var sawPartial = false, sawBudgetStop = false
        for await event in service.answer(.init(queryText: "Research", conversationID: UUID(), scope: .all)) {
            if case .delta = event { sawPartial = true }
            if case .failed(let message) = event { sawBudgetStop = message.contains("budget") }
            if case .finished = event { Issue.record("Truncated response must not be completed") }
        }
        #expect(sawPartial && sawBudgetStop)
    }

    @Test func delegatedWorkerDeepReadsAndReturnsOnlyEvidenceBackedFindings() async throws {
        let fixtures = KnowledgeEvidenceWorkspaceTests()
        let source = fixtures.fixture(summary: "延期是最终决定。")
        let snapshot = fixtures.snapshot([source])
        let client = KnowledgeReplayClient { _, tools, messages in
            let main = tools.contains { $0.name == "knowledge_delegate" }
            if messages.count == 1 {
                if main {
                    return [.toolUseComplete(id: "delegate", name: "knowledge_delegate", inputJSON: KnowledgeJSON.encode([
                        "session_id": source.id.uuidString, "question": "核查决定", "success_criteria": "有来源的决定"])),
                            .messageStop(stopReason: .toolUse)]
                }
                return [.toolUseComplete(id: "read", name: "session_get_summary", inputJSON: KnowledgeJSON.encode(["session_id": source.id.uuidString])),
                        .messageStop(stopReason: .toolUse)]
            }
            guard case .content(.toolResult(_, let contents, let error)) = messages.last?.content.first,
                  case .text(let json) = contents.first,
                  let data = try? LLMJSONValue.parseObject(json) else {
                Issue.record("Missing native worker result"); return [.messageStop(stopReason: .endTurn)]
            }
            #expect(!error)
            if !main {
                guard case .array(let refs) = data["citations"], case .object(let ref) = refs.first,
                      case .string(let id) = ref["evidence_id"] else {
                    Issue.record("Worker must read actual evidence"); return [.messageStop(stopReason: .endTurn)]
                }
                return [.textDelta(KnowledgeJSON.encode(["findings": [["finding": "最终延期", "evidence_ids": [id]]],
                                                        "unresolved": [], "coverage": "claimed full"])),
                        .messageStop(stopReason: .endTurn)]
            }
            if case .string(let job) = data["job_id"] {
                return [.toolUseComplete(id: "poll", name: "knowledge_worker_result", inputJSON: KnowledgeJSON.encode(["job_id": job])),
                        .messageStop(stopReason: .toolUse)]
            }
            #expect(data["findings"] != nil)
            #expect(json.contains("not mechanically established"))
            return [.textDelta("已核查延期决定。[2]"), .messageStop(stopReason: .endTurn)]
        }
        var service = KnowledgeQAService()
        service.dependencies.planner = { _, _, _, _ in .fallback(for: "") }
        service.agentClientFactory = { client }
        service.scopeSnapshotProvider = { snapshot }
        service.skillsProvider = { [] }
        var finished = false
        for await event in service.answer(.init(queryText: "核查决定", conversationID: UUID(), scope: .all)) {
            if case .finished = event { finished = true }
            if case .failed(let message) = event { Issue.record("\(message)") }
        }
        #expect(finished)
    }

    @Test func parallelBranchErrorsDoNotLoseSummaryOrToolResults() async throws {
        let fixtures = KnowledgeEvidenceWorkspaceTests()
        let source = fixtures.fixture(summary: "最终决定延期，因为测试尚未完成。")
        let snapshot = fixtures.snapshot([source])
        let client = KnowledgeReplayClient { index, _, messages in
            if index == 0 {
                return [.toolUseComplete(id: "good", name: "session_get_summary", inputJSON: KnowledgeJSON.encode(["session_id": source.id.uuidString])),
                        .toolUseComplete(id: "bad", name: "session_get_segments", inputJSON: "{\"session_id\":false}"),
                        .messageStop(stopReason: .toolUse)]
            }
            let results = messages.last?.content ?? []
            #expect(results.count == 2)
            if case .content(.toolResult(let id, let content, let isError)) = results[0] {
                #expect(id == "good"); #expect(!isError)
                if case .text(let text) = content.first { #expect(text.contains("最终决定延期")); #expect(text.contains("payload_ref")) }
            } else { Issue.record("Missing full tool observation") }
            if case .content(.toolResult(let id, _, let isError)) = results[1] { #expect(id == "bad"); #expect(isError) }
            else { Issue.record("Missing recoverable error result") }
            return [.textDelta("摘要记录了延期决定。[2]"), .messageStop(stopReason: .endTurn)]
        }
        var service = KnowledgeQAService()
        service.dependencies.planner = { _, _, _, _ in .fallback(for: "") }
        service.agentClientFactory = { client }
        service.scopeSnapshotProvider = { snapshot }
        service.skillsProvider = { [] }
        var finished = 0
        for await event in service.answer(.init(queryText: "为什么延期？", conversationID: UUID(), scope: .all)) {
            if case .finished = event { finished += 1 }
            if case .failed(let text) = event { Issue.record("\(text)") }
        }
        #expect(finished == 1)
    }
}

private final class KnowledgeReplayClient: AgentClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let replay: @Sendable (Int, [AgentToolSchema], [AgentRequestMessage]) -> [AgentStreamEvent]
    init(_ replay: @escaping @Sendable (Int, [AgentToolSchema], [AgentRequestMessage]) -> [AgentStreamEvent]) { self.replay = replay }
    func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage], context: AgentRequestContext) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        lock.lock(); let index = count; count += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in replay(index, tools, messages) { continuation.yield(event) }
            continuation.finish()
        }
    }
}
