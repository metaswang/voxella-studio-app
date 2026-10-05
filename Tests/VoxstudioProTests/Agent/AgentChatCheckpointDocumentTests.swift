import AppKit
import Foundation
import Testing
@testable import VoxstudioPro

/// Exercise AppKit's asynchronous document writer, rather than only an in-memory
/// session callback. No window controllers, remote providers or media jobs start.
@Suite("Agent chat document checkpoints", .serialized)
@MainActor
struct AgentChatCheckpointDocumentTests {
    @Test func toolAndStreamingCheckpointsReachDiskBeforeTheRunFinishes() async throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Checkpoint.voxella", isDirectory: true)
        let document = configuredDocument(at: package)
        let archive = imageHistory()
        let suite = "AgentChatCheckpointDocumentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = CheckpointStreamProbe()
        let service = AgentService(userDefaults: defaults, transportOverride: .hosted,
            checkpointInterval: .milliseconds(20), clientFactory: { _ in CheckpointProbeClient(probe: probe) })
        service.editor = document.editorViewModel
        service.sessions = [archive]
        service.newChat()
        let conversationID = try #require(service.currentSessionId)
        document.editorViewModel.agentService.sessions = service.sessions
        try await bootstrap(document, at: package)

        // The controlled service uses its injected stream factory. Bridge its
        // immutable sessions into the document's normal snapshot source, then
        // invoke exactly the production checkpoint callback.
        service.onSessionsChanged = { [weak document, weak service] in
            guard let document, let service else { return }
            document.editorViewModel.agentService.sessions = service.sessions
            document.updateChangeCount(.changeDone)
            document.scheduleProjectCheckpointAutosave()
        }
        defer { service.onSessionsChanged = nil; service.cancel() }
        service.send(text: "Inspect the timeline and explain the result.", mentions: [])
        try await waitUntil { probe.requestCount == 1 }
        probe.yield(.toolUseComplete(id: "checkpoint-tool", name: "get_timeline", inputJSON: "{}"), request: 0)
        probe.yield(.messageStop(stopReason: .toolUse), request: 0)
        probe.finish(request: 0)
        try await waitUntil { probe.requestCount == 2 }

        try await waitUntil {
            persistedSession(conversationID, at: package)?.messages.contains { message in
                message.blocks.contains { block in
                    if case let .toolResult(id, _, isError) = block { return id == "checkpoint-tool" && !isError }
                    return false
                }
            } == true
        }
        #expect(service.isStreaming)
        probe.yield(.textDelta("The timeline has been inspected. "), request: 1)
        try await waitUntil {
            persistedSession(conversationID, at: package)?.messages.contains {
                textContent($0).contains("The timeline has been inspected.")
            } == true
        }
        // This producer remains open, so persistence cannot rely on run teardown.
        #expect(service.isStreaming)
        probe.yield(.textDelta("No changes were made."), request: 1)
        probe.yield(.messageStop(stopReason: .endTurn), request: 1)
        probe.finish(request: 1)
        try await waitUntil { !service.isStreaming }
        let expected = try #require(service.sessions.first { $0.id == conversationID }).messages
        try await waitUntil { persistedSession(conversationID, at: package)?.messages == expected }
        try await waitUntil { !document.hasUnautosavedChanges }
        await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
        #expect(textContent(try #require(expected.last)) == "The timeline has been inspected. No changes were made.")
        #expect(try #require(persistedSession(archive.id, at: package)).messages == archive.messages)
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent(Project.timelineFilename).path))
        print("Agent checkpoint document saved_tool_result=true saved_partial_while_streaming=true final_messages=\(expected.count)")
    }

    @Test func checkpointsDuringAnActiveWriterCoalesceAndKeepTheLatestSnapshot() async throws {
        _ = NSApplication.shared
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Coalesced.voxella", isDirectory: true)
        let document = GatedCheckpointDocument()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        let archive = imageHistory()
        let service = document.editorViewModel.agentService
        service.newChat()
        let conversationID = try #require(service.currentSessionId)
        service.sessions.append(archive)
        try await bootstrap(document, at: package)
        document.writerProbe.arm(conversationID: conversationID)
        defer { document.writerProbe.release(); service.onSessionsChanged = nil; service.cancel() }
        service.onSessionsChanged = { [weak document] in
            document?.updateChangeCount(.changeDone)
            document?.scheduleProjectCheckpointAutosave()
        }

        service.messages = [AgentMessage(role: .user, blocks: [.text("The first immutable snapshot")])]
        service.postSystemNotice("checkpoint first")
        try await waitUntil { document.writerProbe.isPaused }
        #expect(document.writerProbe.firstWriterWasBackground)

        // The writer now holds snapshot A. New checkpoints may update the live
        // sessions, but must not enqueue one full save per token/notification.
        var maximumHeartbeatDelay = 0.0
        for step in 0..<12 {
            let tick = ContinuousClock.now
            service.messages = [AgentMessage(role: .assistant, blocks: [.text("latest checkpoint \(step)")])]
            service.postSystemNotice("checkpoint notification \(step)")
            try await Task.sleep(for: .milliseconds(10))
            pumpRunLoop()
            let delay = max(0, tick.duration(to: .now).checkpointSeconds - 0.01)
            maximumHeartbeatDelay = max(maximumHeartbeatDelay, delay)
            #expect(delay < 0.5)
        }
        let expected = try #require(service.sessions.first { $0.id == conversationID }).messages
        document.writerProbe.release()
        try await waitUntil { persistedSession(conversationID, at: package)?.messages == expected }
        try await waitUntil { document.writerProbe.records.count >= 2 }
        try await waitUntil { !document.hasUnautosavedChanges }
        await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(50))
        await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()

        let records = document.writerProbe.records
        #expect(records.count == 2, "Updates during the first save must coalesce into one latest pending save")
        #expect(records.allSatisfy { !$0.wasMainThread })
        #expect(records.first?.texts.contains("The first immutable snapshot") == true)
        #expect(records.first?.texts.contains("latest checkpoint 11") == false)
        #expect(records.last?.texts.contains("latest checkpoint 11") == true)
        #expect(!document.writerProbe.didTimeOut)
        #expect(try #require(persistedSession(archive.id, at: package)).messages == archive.messages)
        print("Agent checkpoint coalescing writes=\(records.count) image_history_bytes=\(imagePayload.utf8.count) worst_heartbeat_delay_ms=\(Int(maximumHeartbeatDelay * 1000))")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agent-document-checkpoint-\(UUID())", isDirectory: true)
    }

    private func pumpRunLoop() {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }

    private func configuredDocument(at package: URL) -> VideoProject {
        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        return document
    }

    private func bootstrap(_ document: VideoProject, at package: URL) async throws {
        // Establish a real on-disk document without makeWindowControllers(),
        // which also activates search, restoration and the full editor shell.
        try document.write(to: package, ofType: VideoProject.typeIdentifier)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        await document.editorViewModel.projectPackageCoordinator.waitUntilIdle()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func persistedSession(_ id: UUID, at package: URL) -> ChatSession? {
        let path = package.appendingPathComponent(ChatSessionStore.dirName).appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatSession.self, from: data)
    }

    private func textContent(_ message: AgentMessage) -> String {
        message.blocks.compactMap { if case let .text(text) = $0 { return text }; return nil }.joined()
    }

    private var imagePayload: String { Data(repeating: 0x2A, count: 2 * 1024 * 1024).base64EncodedString() }

    private func imageHistory() -> ChatSession {
        ChatSession(title: "Archived large tool-image history", messages: [
            AgentMessage(role: .assistant, blocks: [.toolUse(id: "archived-image", name: "inspect_timeline", inputJSON: "{}")]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseId: "archived-image", content: [
                .image(base64: imagePayload, mediaType: "image/jpeg")
            ], isError: false)]),
            AgentMessage(role: .assistant, blocks: [.text("The archived frame has been verified.")])
        ], isOpen: false)
    }
}

private final class GatedCheckpointDocument: VideoProject {
    nonisolated let writerProbe = CheckpointWriterProbe()

    override func write(to url: URL, ofType typeName: String) throws {
        writerProbe.pauseIfArmed()
        try super.write(to: url, ofType: typeName)
        writerProbe.recordWrittenSession(at: url)
    }
}

private final class CheckpointWriterProbe: @unchecked Sendable {
    struct Record: Sendable {
        let wasMainThread: Bool
        let texts: [String]
    }
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var conversationID: UUID?
    private var armed = false
    private var paused = false
    private var background = false
    private var timedOut = false
    private var writes: [Record] = []

    var isPaused: Bool { lock.withLock { paused } }
    var firstWriterWasBackground: Bool { lock.withLock { background } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    var records: [Record] { lock.withLock { writes } }

    func arm(conversationID: UUID) {
        lock.withLock {
            self.conversationID = conversationID
            armed = true
            writes.removeAll()
        }
    }

    func pauseIfArmed() {
        let shouldPause = lock.withLock {
            guard armed else { return false }
            armed = false
            paused = true
            background = !Thread.isMainThread
            return background
        }
        // Never block the main thread if AppKit regresses to a synchronous
        // writer: the background-writer assertion will report that failure.
        if shouldPause, gate.wait(timeout: .now() + 5) == .timedOut {
            lock.withLock { timedOut = true }
        }
    }

    func release() { gate.signal() }

    func recordWrittenSession(at package: URL) {
        guard let id = lock.withLock({ conversationID }) else { return }
        let path = package.appendingPathComponent(ChatSessionStore.dirName).appendingPathComponent("\(id).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = (try? Data(contentsOf: path)).flatMap { try? decoder.decode(ChatSession.self, from: $0) }
        let texts: [String] = session?.messages.flatMap { message in
            message.blocks.compactMap { block -> String? in
                if case let .text(text) = block { return text }
                return nil
            }
        } ?? []
        lock.withLock { writes.append(Record(wasMainThread: Thread.isMainThread, texts: texts)) }
    }
}

private struct CheckpointProbeClient: AgentClient {
    let probe: CheckpointStreamProbe

    func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage], context: AgentRequestContext) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        probe.stream()
    }
}

private final class CheckpointStreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<AgentStreamEvent, Error>.Continuation] = []
    var requestCount: Int { lock.withLock { continuations.count } }

    func stream() -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in lock.withLock { continuations.append(continuation) } }
    }

    func yield(_ event: AgentStreamEvent, request: Int) {
        lock.withLock { continuations[request] }.yield(event)
    }

    func finish(request: Int) { lock.withLock { continuations[request] }.finish() }
}

private extension Duration {
    var checkpointSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
