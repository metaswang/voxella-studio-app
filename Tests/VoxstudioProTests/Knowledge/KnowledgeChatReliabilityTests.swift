import AppKit
import Darwin
import SwiftUI
import Testing
@testable import VoxstudioPro

/// Controlled streams exercise the actual controller without network or model loading.
private final class KnowledgeAnswerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [UUID: AsyncStream<KnowledgeAnswerEvent>.Continuation] = [:]
    private var requests: [UUID] = []

    var requestIDs: [UUID] { lock.withLock { requests } }

    func answer(_ request: KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> {
        let (stream, continuation) = AsyncStream<KnowledgeAnswerEvent>.makeStream()
        lock.withLock {
            streams[request.requestID] = continuation
            requests.append(request.requestID)
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.streams.removeValue(forKey: request.requestID) }
        }
        return stream
    }

    func yield(_ event: KnowledgeAnswerEvent, to id: UUID) {
        let continuation = lock.withLock { streams[id] }
        continuation?.yield(event)
    }

    func finish(_ id: UUID) {
        let continuation = lock.withLock { streams[id] }
        continuation?.finish()
    }
}

@Suite("Knowledge chat reliability", .serialized)
@MainActor
struct KnowledgeChatReliabilityTests {
    @Test func measurementsGrowShrinkAndClampWithoutChangingBindings() {
        let short = KnowledgeComposerMetrics.height(text: "hello", width: 300, fontSize: 14)
        let trailing = KnowledgeComposerMetrics.height(text: "hello\n\n", width: 300, fontSize: 14)
        #expect(trailing > short)
        let long = String(repeating: "知识库输入测试 ", count: 200)
        let capped = KnowledgeComposerMetrics.height(text: long, width: 300, fontSize: 14)
        #expect(capped > trailing)
        #expect(capped == KnowledgeComposerMetrics.height(text: long, width: 100, fontSize: 14))
        #expect(KnowledgeComposerMetrics.height(text: "", width: 300, fontSize: 14) == short)
        #expect(KnowledgeComposerMetrics.height(text: long, width: .infinity, fontSize: 14) == short)
        let medium = String(repeating: "wrap ", count: 20)
        #expect(KnowledgeComposerMetrics.height(text: medium, width: 150, fontSize: 14)
            > KnowledgeComposerMetrics.height(text: medium, width: 500, fontSize: 14))
    }

    @Test func returnIsDeferredDeduplicatedAndPreservesTheQuestionSnapshot() async throws {
        var submissions: [String] = []
        let editor = KnowledgeComposerTextEditor(text: .constant("question"), placeholder: "Ask") {
            submissions.append($0)
        }
        let coordinator = editor.makeCoordinator()
        coordinator.submit("first question")
        coordinator.submit("repeat")
        #expect(submissions.isEmpty)
        try await waitUntil { submissions.count == 1 }
        #expect(submissions == ["first question"])
        coordinator.isActive = false
        coordinator.submit("after removal")
        try await Task.sleep(for: .milliseconds(20))
        #expect(submissions.count == 1)
        #expect(!KnowledgeComposerTextEditor.Coordinator.shouldSubmit(hasMarkedText: true, shiftHeld: false))
        #expect(!KnowledgeComposerTextEditor.Coordinator.shouldSubmit(hasMarkedText: false, shiftHeld: true))
        #expect(KnowledgeComposerTextEditor.Coordinator.shouldSubmit(hasMarkedText: false, shiftHeld: false))
    }

    @Test func cancellationRejectsLateResultsAndKeepsAcceptedQuestions() async throws {
        let (controller, store, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "first")
        try await waitUntil { probe.requestIDs.count == 1 }
        let first = probe.requestIDs[0]
        controller.cancelAnswer()
        #expect(!controller.isAnswering)
        #expect(!controller.messages.contains(where: { $0.isStreaming }))
        #expect(controller.errorMessage == nil)
        controller.send(query: "second")
        try await waitUntil { probe.requestIDs.count == 2 }
        probe.yield(.finished("late first result"), to: first)
        probe.yield(.finished("second answer"), to: probe.requestIDs[1])
        try await waitUntil { !controller.isAnswering }
        #expect(controller.messages.map(\.content) == ["first", "second", "second answer"])
        #expect(controller.errorMessage == nil)
        let persisted = try await store.messages(for: try #require(controller.conversation).id)
        #expect(persisted.map(\.content) == controller.messages.map(\.content))
    }

    @Test func firstTerminalEventCompletesEvenIfTheProducerStaysOpen() async throws {
        let (controller, store, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "question")
        try await waitUntil { probe.requestIDs.count == 1 }
        let id = probe.requestIDs[0]
        probe.yield(.recoveryActions([.aiSettings]), to: id)
        probe.yield(.finished("answer"), to: id)
        probe.yield(.finished("duplicate"), to: id)
        try await waitUntil { !controller.isAnswering }
        let persisted = try await store.messages(for: try #require(controller.conversation).id)
        #expect(persisted.map(\.content) == ["question", "answer"])
        #expect(persisted.last?.recoveryActions == [.aiSettings])
    }

    @Test func newConditionsCancelOldRunAndIgnoreLateResults() async throws {
        let (controller, _, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "Compare all meetings")
        try await waitUntil { probe.requestIDs.count == 1 }
        let oldID = probe.requestIDs[0]
        controller.send(query: "Only the final meeting risks")
        try await waitUntil { probe.requestIDs.count == 2 }
        let newID = probe.requestIDs[1]
        probe.yield(.delta("obsolete worker answer"), to: oldID)
        probe.yield(.finished("obsolete answer"), to: oldID)
        probe.yield(.finished("final meeting risks"), to: newID)
        try await waitUntil { !controller.isAnswering }
        #expect(!controller.messages.contains { $0.content.contains("obsolete") })
        #expect(controller.messages.last?.content == "final meeting risks")
    }

    @Test func cancellationKeepsThePartialAnswerAndFailureEndsTheRound() async throws {
        let (controller, store, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "first")
        try await waitUntil { probe.requestIDs.count == 1 }
        probe.yield(.delta("partial answer"), to: probe.requestIDs[0])
        try await waitUntil { controller.messages.last?.content == "partial answer" }
        controller.cancelAnswer()
        #expect(controller.messages.last?.isStreaming == false)
        try await Task.sleep(for: .milliseconds(30))
        controller.send(query: "second")
        try await waitUntil { probe.requestIDs.count == 2 }
        probe.yield(.failed("provider timed out"), to: probe.requestIDs[1])
        try await waitUntil { !controller.isAnswering }
        #expect(controller.errorMessage == "provider timed out")
        #expect(!controller.messages.contains(where: { $0.isStreaming }))
        let persisted = try await store.messages(for: try #require(controller.conversation).id)
        #expect(persisted.map(\.content) == ["first", "partial answer", "second", "provider timed out"])
    }

    @Test func incompleteStreamClearsItsPlaceholderAndReportsTheFailure() async throws {
        let (controller, _, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "question")
        try await waitUntil { probe.requestIDs.count == 1 }
        probe.finish(probe.requestIDs[0])
        try await waitUntil { !controller.isAnswering }
        #expect(controller.messages.map(\.content) == ["question"])
        #expect(controller.errorMessage != nil)
    }

    @Test func providerFailurePreservesPublishedEvidenceAndReportsTheError() async throws {
        let (controller, store, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "question")
        try await waitUntil { probe.requestIDs.count == 1 }
        let id = probe.requestIDs[0]
        probe.yield(.delta("Already confirmed evidence."), to: id)
        probe.yield(.failed("research budget reached"), to: id)
        try await waitUntil { !controller.isAnswering }
        #expect(controller.messages.last?.content == "Already confirmed evidence.")
        #expect(controller.messages.last?.isStreaming == false)
        #expect(controller.errorMessage == "research budget reached")
        let persisted = try await store.messages(for: try #require(controller.conversation).id)
        #expect(persisted.last?.content == "Already confirmed evidence.")
    }

    @Test func completeServiceResultsDoNotReplaySyntheticDeltas() async {
        var service = KnowledgeQAService()
        service.useAgentRuntime = false
        service.skillsProvider = { [] }
        service.dependencies = KnowledgeQAExecutionDependencies(
            planner: { query, _, _, _ in .fallback(for: query) },
            hybridRecall: { _, _ in [] }, graphRecall: { _, _ in [] },
            reranker: { _, chunks in chunks.map { _ in 0.9 } }
        )
        var terminals = 0
        var deltas = 0
        for await event in service.answer(KnowledgeQARequest(queryText: "test evidence", conversationID: UUID(), scope: .all)) {
            if case .finished = event { terminals += 1 }
            if case .delta = event { deltas += 1 }
        }
        #expect(terminals == 1)
        #expect(deltas == 0)
    }

    @Test func switchingConversationsRejectsTheOldAnswer() async throws {
        let (controller, store, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.send(query: "old question")
        try await waitUntil { probe.requestIDs.count == 1 }
        let oldRequest = probe.requestIDs[0]
        await controller.loadConversation(for: .session(UUID()))
        probe.yield(.finished("old answer"), to: oldRequest)
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.messages.isEmpty)
        #expect(controller.errorMessage == nil)
        #expect(try await store.messages(for: try #require(controller.conversation).id).isEmpty)
    }

    @Test func longHistoryReturnAndWaitingLayoutsRemainResponsive() async throws {
        let (controller, _, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.messages = [history(conversationID: try #require(controller.conversation).id)]
        let (window, host) = makeHost(controller, width: 640)
        defer { window.close() }
        let originalScale = AppZoomScale.shared.scale
        defer { AppZoomScale.shared.setScale(originalScale) }
        for scale in [AppZoomScale.minimumScale, 1, AppZoomScale.maximumScale] {
            AppZoomScale.shared.setScale(scale)
            for width in [CGFloat(360), 640, 1000, 640] {
                host.rootView = KnowledgeChatPane(controller: controller, availableWidth: width)
                window.setContentSize(NSSize(width: width, height: 700))
                layout(host)
            }
        }
        AppZoomScale.shared.setScale(originalScale)
        controller.draft = "总结这节课"
        layout(host)
        let editor = try #require(findEditor(in: host.view))
        let handled = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(handled == true)
        #expect(!controller.isAnswering)
        try await waitUntil { probe.requestIDs.count == 1 }
        #expect(controller.draft.isEmpty)
        layout(host)
        let requestID = probe.requestIDs[0]
        for status in ["Understanding question…", "Searching knowledge…", "Composing answer…"] {
            probe.yield(.status(status), to: requestID)
            try await Task.sleep(for: .milliseconds(20))
            layout(host)
        }
        probe.yield(.finished("| 项目 | 内容 |\n|---|---|\n| 结论 | 测试回答 |\n\n```swift\nlet value = 1\n```"), to: requestID)
        try await waitUntil { !controller.isAnswering }
        layout(host)
        #expect(!controller.messages.contains(where: { $0.isStreaming }))
    }

    @Test func completedLongAnswerKeepsTheBottomVisible() async throws {
        let (controller, _, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = history(conversationID: try #require(controller.conversation).id)
        controller.messages = [seed]
        let (window, host) = makeHost(controller, width: 640)
        defer { window.close() }
        layout(host)
        let scroll = try #require(findChatScrollView(in: host.view))
        controller.send(query: "summarize")
        try await waitUntil { probe.requestIDs.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        layout(host)
        probe.yield(.finished(seed.content + "\n\n" + seed.content), to: probe.requestIDs[0])
        try await waitUntil { !controller.isAnswering }
        try await waitUntil {
            layout(host)
            guard let document = scroll.documentView else { return false }
            return document.bounds.maxY - scroll.documentVisibleRect.maxY <= 48
        }
    }

    @Test func growingMultiTurnHistorySettlesLayoutAndMemory() async throws {
        let (controller, _, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = try #require(controller.conversation).id
        let citation = try #require(history(conversationID: conversationID).citations.first)
        for _ in 0..<3 {
            controller.messages.append(.init(conversationID: conversationID, role: .user,
                content: "transcript 认为 coding-agent 的 best practices 发生了什么变化？"))
            controller.messages.append(.init(conversationID: conversationID, role: .assistant,
                content: "能力进步很快，最佳实践也在迅速变化。\n\n" + String(repeating: "积累的冗长指令需要重新审视。", count: 12),
                citations: [citation]))
        }
        // A local incident replay can supply the saved conversation without any
        // provider requests or changes to the user's conversation store.
        if let path = ProcessInfo.processInfo.environment["VOXSTUDIO_KB_LAYOUT_FIXTURE"] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            controller.messages = try decoder.decode([KnowledgeMessage].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            if controller.messages.last?.role == .user { controller.messages.removeLast() }
        }
        let (window, host) = makeHost(controller, width: 1000)
        defer { window.close() }
        window.orderFront(nil)
        settleVisibleLayout(host)
        var baseline = footprint()
        var peak = baseline
        for cycle in 0..<24 {
            controller.send(query: "accumulated bloated instructions 会造成什么问题？")
            try await waitUntil { probe.requestIDs.count == cycle + 1 }
            try await Task.sleep(for: .milliseconds(30))
            settleVisibleLayout(host)
            let id = probe.requestIDs[cycle]
            probe.yield(.citations([citation]), to: id)
            for text in ["- 指令随着时间积累变得冗长。", "\n\n- 可能增加维护和资源消耗。"] {
                probe.yield(.delta(text), to: id)
                try await Task.sleep(for: .milliseconds(30))
                settleVisibleLayout(host)
            }
            probe.yield(.finished("- 指令随着时间积累变得冗长。\n\n- 可能增加维护和资源消耗。"), to: id)
            try await waitUntil { !controller.isAnswering }
            try await Task.sleep(for: .milliseconds(30))
            settleVisibleLayout(host)
            if cycle == 3 { baseline = footprint(); peak = baseline }
            if cycle >= 4 { peak = max(peak, footprint()) }
        }
        let seconds = max(0, Int(ProcessInfo.processInfo.environment["VOXSTUDIO_KB_STRESS_SECONDS"] ?? "0") ?? 0)
        if seconds > 0 {
            controller.send(query: "waiting after a growing conversation")
            try await waitUntil { probe.requestIDs.count == 25 }
            let clock = ContinuousClock()
            let started = clock.now
            var lastReport = -30.0
            while started.duration(to: clock.now) < .seconds(seconds) {
                let tick = clock.now
                try await Task.sleep(for: .milliseconds(100))
                settleVisibleLayout(host)
                #expect(tick.duration(to: clock.now) < .milliseconds(500))
                peak = max(peak, footprint())
                let elapsed = started.duration(to: clock.now).secondsValue
                if elapsed - lastReport >= 30 {
                    print("KB growing history waiting_s=\(Int(elapsed)) footprint_mb=\(footprint() / 1024 / 1024)")
                    lastReport = elapsed
                }
            }
            controller.cancelAnswer()
            settleVisibleLayout(host)
        }
        #expect(peak < baseline + 100 * 1024 * 1024)
        print("KB growing history baseline_mb=\(baseline / 1024 / 1024) peak_mb=\(peak / 1024 / 1024)")
    }

    /// Set VOXSTUDIO_KB_STRESS_SECONDS=600 for the ten-minute acceptance run.
    @Test func repeatedSendCancelAndWaitingMemoryStayBounded() async throws {
        let (controller, store, probe, root) = try await makeController()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = try #require(controller.conversation).id
        let seed = history(conversationID: conversationID)
        controller.messages = [seed]
        let (window, host) = makeHost(controller, width: 640)
        defer { window.close() }
        layout(host)
        var baseline: UInt64 = 0
        var peak: UInt64 = 0
        for cycle in 0..<55 {
            controller.messages = [seed]
            try await store.clear(conversationID: conversationID)
            controller.draft = "总结这节课"
            layout(host)
            let editor = try #require(findEditor(in: host.view))
            _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            try await waitUntil { probe.requestIDs.count == cycle + 1 }
            layout(host)
            if cycle.isMultiple(of: 2) {
                controller.cancelAnswer()
            } else {
                probe.yield(.finished(seed.content), to: probe.requestIDs[cycle])
                try await waitUntil { !controller.isAnswering }
            }
            layout(host)
            try await Task.sleep(for: .milliseconds(20))
            let memory = footprint()
            if cycle == 4 { baseline = memory }
            if cycle >= 5 { peak = max(peak, memory) }
        }
        #expect(peak < baseline + 200 * 1024 * 1024)
        let seconds = max(0, Int(ProcessInfo.processInfo.environment["VOXSTUDIO_KB_STRESS_SECONDS"] ?? "0") ?? 0)
        if seconds > 0 {
            controller.messages = [seed]
            controller.send(query: "waiting")
            try await waitUntil { probe.requestIDs.count == 56 }
            let clock = ContinuousClock()
            let started = clock.now
            var samples: [(Double, UInt64)] = []
            var maximumDelay = 0.0
            var lastReport = -60.0
            while started.duration(to: clock.now) < .seconds(seconds) {
                let tick = clock.now
                try await Task.sleep(for: .milliseconds(100))
                layout(host)
                let delay = tick.duration(to: clock.now).secondsValue - 0.1
                maximumDelay = max(maximumDelay, delay)
                #expect(delay < 0.5)
                let elapsed = started.duration(to: clock.now).secondsValue
                let memory = footprint()
                peak = max(peak, memory)
                samples.append((elapsed, memory))
                if elapsed - lastReport >= 60 {
                    print("KB stress elapsed_s=\(Int(elapsed)) footprint_mb=\(memory / 1024 / 1024) peak_delta_mb=\((peak > baseline ? peak - baseline : 0) / 1024 / 1024)")
                    lastReport = elapsed
                }
            }
            if let early = samples.first(where: { $0.0 >= Double(seconds) - 300 }), let end = samples.last {
                #expect(end.1 < early.1 + 50 * 1024 * 1024)
            }
            let stopped = clock.now
            controller.cancelAnswer()
            layout(host)
            #expect(stopped.duration(to: clock.now) < .milliseconds(500))
            #expect(!controller.messages.contains(where: { $0.isStreaming }))
            #expect(peak < baseline + 200 * 1024 * 1024)
            print("KB stress finished baseline_mb=\(baseline / 1024 / 1024) peak_mb=\(peak / 1024 / 1024) worst_heartbeat_delay_ms=\(Int(maximumDelay * 1000))")
        }
    }

    private func makeController() async throws -> (KnowledgeBaseController, KnowledgeChatStore, KnowledgeAnswerProbe, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kb-reliability-\(UUID())")
        let store = KnowledgeChatStore(rootURL: root)
        let probe = KnowledgeAnswerProbe()
        let controller = KnowledgeBaseController(chatStore: store, answerProvider: { probe.answer($0) },
            availabilityProvider: { .ready }, modelPlanProvider: {
                .knowledgeQAPlan(answerModelID: nil, includeReranker: false, isInstalled: { _ in true })
            })
        controller.conversation = try await store.conversation(for: .all)
        return (controller, store, probe, root)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
        try #require(condition())
    }

    private func history(conversationID: UUID) -> KnowledgeMessage {
        let content = "# Session summary\n\n" + (0..<25).map { "- Topic \($0): " + String(repeating: "knowledge summary ", count: 8) }.joined(separator: "\n")
        let citation = KnowledgeSourceRef(sourceID: UUID().uuidString, sourceType: "session", title: "A long session title", uri: nil,
            page: nil, startTime: 0, endTime: 120, parentID: nil, chunkIndex: nil, language: "en", speaker: nil, snippet: nil, matchText: nil)
        return KnowledgeMessage(conversationID: conversationID, role: .assistant, content: content, citations: [citation])
    }

    private func makeHost(_ controller: KnowledgeBaseController, width: CGFloat) -> (NSWindow, NSHostingController<KnowledgeChatPane>) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: KnowledgeChatPane(controller: controller, availableWidth: width))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.frame = window.contentLayoutRect
        return (window, host)
    }

    private func layout(_ host: NSHostingController<KnowledgeChatPane>) {
        let start = ContinuousClock().now
        host.view.layoutSubtreeIfNeeded()
        #expect(start.duration(to: ContinuousClock().now) < .milliseconds(500))
    }

    private func settleVisibleLayout(_ host: NSHostingController<KnowledgeChatPane>) {
        let start = ContinuousClock().now
        host.view.layoutSubtreeIfNeeded()
        // SwiftUI also flushes graph transactions from a native run-loop
        // observer. Synchronous layout alone does not exercise that path.
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        #expect(start.duration(to: ContinuousClock().now) < .milliseconds(500))
    }

    private func findEditor(in view: NSView) -> NSTextView? {
        if let scroll = view as? ComposerScrollView, let text = scroll.documentView as? NSTextView { return text }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }

    private func findChatScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, !(scroll is ComposerScrollView) { return scroll }
        return view.subviews.lazy.compactMap { findChatScrollView(in: $0) }.first
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        #expect(result == KERN_SUCCESS)
        return info.phys_footprint
    }
}

private extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
