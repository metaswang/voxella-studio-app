import Foundation
import Testing
@testable import VoxstudioPro

@Suite("Editor agent run reliability")
@MainActor
struct AgentServiceReliabilityTests {
    @Test func submittedQuestionAndFinishedAnswerAreCheckpointed() async throws {
        let (service, probe, defaults, suite) = makeService()
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        var snapshots: [[ChatSession]] = []
        service.onSessionsChanged = { snapshots.append(service.sessions) }

        service.send(text: "question", mentions: [])
        let sessionID = try #require(service.currentSessionId)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].first { $0.id == sessionID }?.messages.map(\.blocks) == [[.text("question")]])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.textDelta("answer"), request: 0)
        probe.yield(.messageStop(stopReason: .endTurn), request: 0)
        probe.finish(request: 0)
        try await waitUntil { !service.isStreaming }

        #expect(service.sessions.first { $0.id == sessionID }?.messages.last?.blocks == [.text("answer")])
        #expect(snapshots.count == 2)
        service.onSessionsChanged = nil
    }

    @Test func continuousDeltasUsePeriodicCheckpointsAndCancelFlushesTheTail() async throws {
        let (service, probe, defaults, suite) = makeService(checkpointInterval: .milliseconds(100))
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        var checkpoints = 0
        service.onSessionsChanged = { checkpoints += 1 }
        service.send(text: "question", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        for _ in 0..<40 { probe.yield(.textDelta("a"), request: 0) }
        try await waitUntil { service.messages.last?.blocks == [.text(String(repeating: "a", count: 40))] }
        #expect(checkpoints == 1)
        try await waitUntil { checkpoints == 2 }
        #expect(service.sessions.first?.messages.last?.blocks == [.text(String(repeating: "a", count: 40))])

        for _ in 0..<20 { probe.yield(.textDelta("b"), request: 0) }
        let expected = String(repeating: "a", count: 40) + String(repeating: "b", count: 20)
        try await waitUntil { service.messages.last?.blocks == [.text(expected)] }
        service.cancel()
        #expect(checkpoints == 3)
        #expect(service.sessions.first?.messages.last?.blocks == [.text(expected)])
        try await Task.sleep(for: .milliseconds(150))
        #expect(checkpoints == 3)
        #expect(!service.isStreaming)
        service.onSessionsChanged = nil
    }

    @Test func completedToolRoundIsCheckpointedBeforeTheNextModelRequest() async throws {
        let (service, probe, defaults, suite) = makeService()
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        var snapshots: [[ChatSession]] = []
        service.onSessionsChanged = { snapshots.append(service.sessions) }
        service.send(text: "inspect timeline", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.toolUseComplete(id: "call-1", name: "get_timeline", inputJSON: "{}"), request: 0)
        probe.yield(.messageStop(stopReason: .toolUse), request: 0)
        probe.finish(request: 0)
        try await waitUntil { probe.requestCount == 2 }

        let expected = ToolResult.error("Tool executor unavailable.")
        #expect(service.toolResults["call-1"] == expected)
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.first?.messages.last?.blocks == [
            .toolResult(toolUseId: "call-1", content: expected.content, isError: true)
        ])
        let indexed = service.toolResults
        probe.yield(.textDelta("done"), request: 1)
        try await waitUntil { service.messages.last?.blocks == [.text("done")] }
        #expect(service.toolResults == indexed)
        probe.finish(request: 1)
        try await waitUntil { !service.isStreaming }
        service.onSessionsChanged = nil
    }

    @Test func completedToolSurvivesCancellingTheFollowingTool() async throws {
        var calls = 0
        var waitingTool: CheckedContinuation<ToolResult, Never>?
        let completed = ToolResult.ok("first tool result")
        let (service, probe, defaults, suite) = makeService(toolOperation: { _, _, _ in
            calls += 1
            if calls == 1 { return completed }
            return await withCheckedContinuation { waitingTool = $0 }
        })
        defer {
            service.cancel()
            waitingTool?.resume(returning: .error("test cleanup"))
            defaults.removePersistentDomain(forName: suite)
        }
        var snapshots: [[ChatSession]] = []
        service.onSessionsChanged = { snapshots.append(service.sessions) }
        service.send(text: "run two tools", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.toolUseComplete(id: "first", name: "get_timeline", inputJSON: "{}"), request: 0)
        probe.yield(.toolUseComplete(id: "second", name: "inspect_timeline", inputJSON: "{}"), request: 0)
        probe.yield(.messageStop(stopReason: .toolUse), request: 0)
        probe.finish(request: 0)
        try await waitUntil { waitingTool != nil }

        let resultID = try #require(service.messages.last?.id)
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.first?.messages.last?.blocks == [
            .toolResult(toolUseId: "first", content: completed.content, isError: false)
        ])
        #expect(service.toolResults["first"] == completed)
        service.cancel()
        #expect(service.messages.last?.id == resultID)
        #expect(service.messages.last?.blocks.count == 2)
        #expect(service.toolResults["first"] == completed)
        #expect(service.toolResults["second"] == .error("Cancelled"))
        #expect(snapshots.count == 3)
        #expect(snapshots.last?.first?.messages.last == service.messages.last)

        let cancelledMessages = service.messages
        let lateTool = try #require(waitingTool)
        waitingTool = nil
        lateTool.resume(returning: .ok("late second result"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.messages == cancelledMessages)
        #expect(service.toolResults["second"] == .error("Cancelled"))
        #expect(probe.requestCount == 1)
        #expect(!service.isStreaming)
        service.onSessionsChanged = nil
    }

    @Test func completedBatchMergesToolResultsIntoOneUserMessage() async throws {
        let (service, probe, defaults, suite) = makeService(toolOperation: { name, _, _ in .ok(name) })
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        var checkpoints = 0
        service.onSessionsChanged = { checkpoints += 1 }
        service.send(text: "run two tools", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.toolUseComplete(id: "first", name: "get_timeline", inputJSON: "{}"), request: 0)
        probe.yield(.toolUseComplete(id: "second", name: "inspect_timeline", inputJSON: "{}"), request: 0)
        probe.yield(.messageStop(stopReason: .toolUse), request: 0)
        probe.finish(request: 0)
        try await waitUntil { probe.requestCount == 2 }

        let resultMessages = service.messages.filter {
            $0.role == .user && $0.blocks.contains { if case .toolResult = $0 { true } else { false } }
        }
        #expect(resultMessages.count == 1)
        #expect(resultMessages.first?.blocks == [
            .toolResult(toolUseId: "first", content: [.text("get_timeline")], isError: false),
            .toolResult(toolUseId: "second", content: [.text("inspect_timeline")], isError: false)
        ])
        #expect(checkpoints == 3)
        #expect(service.sessions.first?.messages.last == resultMessages.first)
        probe.finish(request: 1)
        try await waitUntil { !service.isStreaming }
        service.onSessionsChanged = nil
    }

    @Test func terminalMessageStillWaitsForHostedSettlement() async throws {
        let (service, probe, defaults, suite) = makeService()
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        service.send(text: "question", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.textDelta("partial answer"), request: 0)
        probe.yield(.messageStop(stopReason: .endTurn), request: 0)
        try await waitUntil { service.messages.last?.blocks == [.text("partial answer")] }
        #expect(service.isStreaming)
        probe.finish(request: 0, error: AgentClientTransportError.insufficientCredits("settlement failed"))
        try await waitUntil { !service.isStreaming }
        #expect(service.messages.map(\.blocks) == [[.text("question")]])
        guard case .some(.insufficientCredits(_)) = service.streamError else {
            Issue.record("Expected the settlement error after the terminal model event")
            return
        }
        #expect(service.sessions.first?.messages.map(\.blocks) == [[.text("question")]])
    }

    enum SessionTransition: CaseIterable, Equatable, Sendable {
        case newChat, selectSession, closeTab, deleteSession, reloadSessions, cancel, replaceRun
    }

    @Test(arguments: SessionTransition.allCases)
    func cancelledRunCannotChangeTheReplacementRun(transition: SessionTransition) async throws {
        let (service, probe, defaults, suite) = makeService()
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        service.send(text: "old question", mentions: [])
        let oldSession = try #require(service.currentSessionId)
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.textDelta("old partial"), request: 0)
        try await waitUntil { service.messages.last?.blocks == [.text("old partial")] }

        let target = ChatSession(title: "other", messages: [AgentMessage(role: .user, blocks: [.text("seed")])])
        switch transition {
        case .newChat: service.newChat()
        case .selectSession:
            service.sessions.append(target)
            service.selectSession(target.id)
        case .closeTab:
            service.sessions.append(target)
            service.closeTab(oldSession)
        case .deleteSession:
            service.sessions.append(target)
            service.deleteSession(oldSession)
        case .reloadSessions: service.loadSessions(from: nil)
        case .cancel: service.cancel()
        case .replaceRun: break
        }
        if transition != .replaceRun { #expect(!service.isStreaming) }
        service.send(text: "new question", mentions: [])
        try await waitUntil { probe.requestCount == 2 }
        let before = service.messages
        probe.yield(.textDelta("late old answer"), request: 0)
        probe.finish(request: 0, error: URLError(.cannotConnectToHost))
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.isStreaming)
        #expect(service.messages == before)
        #expect(service.streamError == nil)
        probe.yield(.textDelta("new answer"), request: 1)
        probe.finish(request: 1)
        try await waitUntil { !service.isStreaming }
        #expect(service.messages.last?.blocks == [.text("new answer")])
        if transition != .deleteSession && transition != .reloadSessions && transition != .cancel && transition != .replaceRun {
            #expect(service.sessions.first { $0.id == oldSession }?.messages.last?.blocks == [.text("old partial")])
        }
    }

    @Test func delayedClientSelectionCannotClearOrFailANewerRun() async throws {
        let suite = "AgentServiceReliabilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let gate = ClientSelectionGate()
        let probe = EditorAgentStreamProbe()
        let service = AgentService(userDefaults: defaults, transportOverride: .hosted, clientFactory: { _ in
            await gate.select()
        })
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        service.newChat()
        service.send(text: "old question", mentions: [])
        try await waitUntil { gate.pending.count == 1 }
        service.newChat()
        service.send(text: "new question", mentions: [])
        try await waitUntil { gate.pending.count == 2 }
        gate.pending[1].resume(returning: EditorAgentProbeClient(probe: probe))
        try await waitUntil { probe.requestCount == 1 }
        gate.pending[0].resume(returning: nil)
        try await Task.sleep(for: .milliseconds(20))

        #expect(service.isStreaming)
        #expect(service.streamError == nil)
        #expect(probe.requestCount == 1)
        probe.yield(.textDelta("new answer"), request: 0)
        probe.finish(request: 0)
        try await waitUntil { !service.isStreaming }
        #expect(service.messages.map(\.blocks) == [[.text("new question")], [.text("new answer")]])
    }

    @Test func switchingSessionsCancelsTheOldScheduledCheckpoint() async throws {
        let (service, probe, defaults, suite) = makeService(checkpointInterval: .milliseconds(100))
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        var checkpoints = 0
        service.onSessionsChanged = { checkpoints += 1 }
        service.send(text: "old question", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.textDelta("old partial"), request: 0)
        try await waitUntil { service.messages.last?.blocks == [.text("old partial")] }
        service.newChat()
        service.send(text: "new question", mentions: [])
        try await waitUntil { probe.requestCount == 2 }
        let checkpointCount = checkpoints
        let messages = service.messages
        try await Task.sleep(for: .milliseconds(150))

        #expect(checkpoints == checkpointCount)
        #expect(service.messages == messages)
        #expect(service.isStreaming)
        service.onSessionsChanged = nil
    }

    @Test func selectingHistoryRebuildsToolIndexAndNewChatClearsIt() {
        let (service, _, defaults, suite) = makeService()
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        let result = ToolResult(content: [.image(base64: "image", mediaType: "image/png"), .text("metadata")], isError: false)
        let history = ChatSession(messages: [
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "historical-call", name: "inspect_timeline", inputJSON: "{}")]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseId: "historical-call", content: result.content, isError: false)])
        ])
        service.sessions.append(history)
        service.selectSession(history.id)
        #expect(service.toolResults == ["historical-call": result])
        service.newChat()
        #expect(service.toolResults.isEmpty)
    }

    enum HistoryEntry: CaseIterable, Sendable {
        case select, closeCurrentTab, deleteCurrentSession
    }

    @Test(arguments: HistoryEntry.allCases)
    func restoringInterruptedHistoryCancelsOnlyUnfinishedTools(entry: HistoryEntry) throws {
        let (service, _, defaults, suite) = makeService()
        defer { service.cancel(); defaults.removePersistentDomain(forName: suite) }
        let current = try #require(service.currentSessionId)
        let first = ToolResult.ok("completed first")
        let second = ToolResult(content: [.image(base64: "kept image", mediaType: "image/jpeg")], isError: false)
        let history = ChatSession(messages: [
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: "first", name: "get_timeline", inputJSON: "{}"),
                .toolUse(id: "second", name: "inspect_timeline", inputJSON: "{}"),
                .toolUse(id: "pending", name: "get_media", inputJSON: "{}")
            ]),
            AgentMessage(role: .user, blocks: [
                .toolResult(toolUseId: "first", content: first.content, isError: false),
                .toolResult(toolUseId: "second", content: second.content, isError: false)
            ])
        ])
        service.sessions.append(history)
        var snapshots: [[ChatSession]] = []
        service.onSessionsChanged = { snapshots.append(service.sessions) }
        switch entry {
        case .select: service.selectSession(history.id)
        case .closeCurrentTab: service.closeTab(current)
        case .deleteCurrentSession: service.deleteSession(current)
        }

        #expect(service.currentSessionId == history.id)
        #expect(!service.isStreaming)
        #expect(service.messages.count == 2)
        #expect(service.messages.last?.id == history.messages.last?.id)
        #expect(service.messages.last?.blocks.count == 3)
        #expect(service.toolResults == ["first": first, "second": second, "pending": .error("Cancelled")])
        #expect(snapshots.last?.first { $0.id == history.id }?.messages == service.messages)
        service.onSessionsChanged = nil
    }

    private func makeService(
        checkpointInterval: Duration = .seconds(2),
        toolOperation: AgentService.ToolOperation? = nil
    ) -> (AgentService, EditorAgentStreamProbe, UserDefaults, String) {
        let suite = "AgentServiceReliabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let probe = EditorAgentStreamProbe()
        let service = AgentService(
            userDefaults: defaults,
            transportOverride: .hosted,
            checkpointInterval: checkpointInterval,
            clientFactory: { _ in EditorAgentProbeClient(probe: probe) },
            toolOperation: toolOperation
        )
        service.newChat()
        return (service, probe, defaults, suite)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition())
    }
}

@MainActor
private final class ClientSelectionGate {
    var pending: [CheckedContinuation<(any AgentClient)?, Never>] = []

    func select() async -> (any AgentClient)? {
        await withCheckedContinuation { pending.append($0) }
    }
}

private struct EditorAgentProbeClient: AgentClient {
    let probe: EditorAgentStreamProbe

    func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage], context: AgentRequestContext) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        probe.stream()
    }
}

private final class EditorAgentStreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<AgentStreamEvent, Error>.Continuation] = []

    var requestCount: Int { lock.withLock { continuations.count } }

    func stream() -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
        }
    }

    func yield(_ event: AgentStreamEvent, request: Int) {
        let continuation = lock.withLock { continuations[request] }
        continuation.yield(event)
    }

    func finish(request: Int, error: Error? = nil) {
        let continuation = lock.withLock { continuations[request] }
        continuation.finish(throwing: error)
    }
}
