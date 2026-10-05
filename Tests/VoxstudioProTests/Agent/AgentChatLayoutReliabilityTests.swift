import AppKit
import Darwin
import SwiftUI
import Testing
@testable import VoxstudioPro

/// These tests render the production panel in a native window and feed controlled
/// message snapshots. They do not call a provider, load a model, or execute edits.
@Suite("Agent chat layout reliability", .serialized)
@MainActor
struct AgentChatLayoutReliabilityTests {
    @Test func incidentHistoryAndLongPromptSettleAtNarrowWidths() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let saved = try incidentHistory()
        install(saved, in: service)
        let (window, host) = makeHost(editor, width: 400)
        defer { service.cancel(); window.close() }
        let originalScale = AppZoomScale.shared.scale
        defer { AppZoomScale.shared.setScale(originalScale) }

        // Replay the saved ten-message history, followed by the long editing
        // brief that was still only in memory when the incident occurred.
        service.messages.append(AgentMessage(role: .user, blocks: [.text(longEditingBrief)]))
        service.messages.append(AgentMessage(role: .assistant, blocks: []))
        service.isStreaming = true
        for scale in [AppZoomScale.minimumScale, 1, AppZoomScale.maximumScale] {
            AppZoomScale.shared.setScale(scale)
            for width in [CGFloat(340), 400, 640, 1000, 400] {
                window.setContentSize(NSSize(width: width, height: 780))
                settleVisibleLayout(host)
                try await Task.sleep(for: .milliseconds(20))
                settleVisibleLayout(host)
                #expect(host.view.bounds.width.isFinite)
                #expect(host.view.bounds.height.isFinite)
            }
        }
        AppZoomScale.shared.setScale(originalScale)
        service.draft = longEditingBrief
        try await Task.sleep(for: .milliseconds(20))
        settleVisibleLayout(host)
        let inputBeforeClearing = try #require(findInputTextView(in: host.view))
        service.draft = ""
        try await Task.sleep(for: .milliseconds(20))
        settleVisibleLayout(host)
        let inputAfterClearing = try #require(findInputTextView(in: host.view))
        #expect(inputAfterClearing === inputBeforeClearing,
            "Clearing the submitted draft must keep the native text editor identity stable")
        service.messages[service.messages.count - 1].blocks = [.text(longAnswer)]
        service.isStreaming = false
        try await waitForBottom(in: host)
        #expect(service.messages.count == saved.messages.count + 2)
    }

    @Test func toolRoundsReasoningDeltasAndSessionSwitchKeepTheBottomVisible() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let saved = try incidentHistory()
        install(saved, in: service)
        let (window, host) = makeHost(editor, width: 400)
        defer { service.cancel(); window.close() }
        settleVisibleLayout(host)

        service.messages.append(AgentMessage(role: .user, blocks: [.text(longEditingBrief)]))
        service.isStreaming = true
        // Nine assistant/tool-result rounds reproduce the growing history shape
        // (29 messages with the incident's ten-message snapshot), without edits.
        for round in 0..<9 {
            let index = service.messages.count
            let toolID = "layout-tool-\(round)"
            service.messages.append(AgentMessage(role: .assistant, blocks: [
                reasoning(summary: "", complete: false, round: round),
                .toolUse(id: toolID, name: "inspect_timeline", inputJSON: "{\"includeFrames\":true}")
            ]))
            for step in 1...3 {
                service.messages[index].blocks[0] = reasoning(
                    summary: String(repeating: "Check the source interval and preserve the layout. ", count: step * 8),
                    complete: false, round: round)
                try await Task.sleep(for: .milliseconds(20))
                settleVisibleLayout(host)
            }
            // Completion hides the previously visible reasoning, shrinking the
            // row while tool results and another assistant are being inserted.
            service.messages[index].blocks[0] = reasoning(summary: "Verified source interval.", complete: true, round: round)
            service.messages.append(AgentMessage(role: .user, blocks: [
                .toolResult(toolUseId: toolID, content: [.text("{\"round\":\(round),\"ok\":true}")], isError: false)
            ]))
            service.rebuildToolResultIndex()
            #expect(service.toolResults[toolID]?.isError == false)
            settleVisibleLayout(host)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.messages.count == saved.messages.count + 19)

        let finalIndex = service.messages.count
        service.messages.append(AgentMessage(role: .assistant, blocks: [.text("")]))
        for text in ["# Edit completed\n\n", longAnswer, "\n\nAll source audio is muted."] {
            let existing = textContent(service.messages[finalIndex])
            service.messages[finalIndex].blocks = [.text(existing + text)]
            try await Task.sleep(for: .milliseconds(20))
            settleVisibleLayout(host)
        }
        service.isStreaming = false
        try await waitForBottom(in: host)

        let firstID = try #require(service.currentSessionId)
        let originalIDs = service.messages.map(\.id)
        let alternate = ChatSession(title: "Other controlled conversation", messages: [
            AgentMessage(role: .user, blocks: [.text("A different conversation")]),
            AgentMessage(role: .assistant, blocks: [.text("A short answer")])
        ])
        service.sessions.append(alternate)
        service.selectSession(alternate.id)
        #expect(service.messages.map(\.id) == alternate.messages.map(\.id))
        settleVisibleLayout(host)
        service.selectSession(firstID)
        #expect(service.messages.map(\.id) == originalIDs)
        try await waitForBottom(in: host)

        service.messages.append(AgentMessage(role: .assistant, blocks: [.text("Partial answer preserved on cancellation.")]))
        service.isStreaming = true
        settleVisibleLayout(host)
        let started = ContinuousClock().now
        service.cancel()
        settleVisibleLayout(host)
        #expect(started.duration(to: ContinuousClock().now) < .milliseconds(500))
        #expect(!service.isStreaming)
        #expect(textContent(try #require(service.messages.last)) == "Partial answer preserved on cancellation.")
        try await waitForBottom(in: host)
    }

    /// Defaults to a 30-second acceptance run; increase the environment value for
    /// longer observation. Memory excludes provider requests and model loading.
    @Test func repeatedGrowthCancellationAndWaitingStayResponsiveAndBounded() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let saved = try incidentHistory()
        install(saved, in: service)
        let (window, host) = makeHost(editor, width: 400)
        defer { service.cancel(); window.close() }
        settleVisibleLayout(host)

        // Warm the real text/layout caches before recording the memory baseline.
        for round in 0..<5 {
            service.messages = stressMessages(saved.messages, round: round, complete: false)
            service.rebuildToolResultIndex()
            service.isStreaming = true
            try await Task.sleep(for: .milliseconds(20))
            settleVisibleLayout(host)
            service.messages = stressMessages(saved.messages, round: round, complete: true)
            service.rebuildToolResultIndex()
            service.cancel()
            try await Task.sleep(for: .milliseconds(20))
            settleVisibleLayout(host)
        }
        service.messages = stressMessages(saved.messages, round: 0, complete: false)
        service.rebuildToolResultIndex()
        service.isStreaming = true
        settleVisibleLayout(host)
        let baseline = footprint()
        var peak = baseline
        var maximumDelay = 0.0
        var samples: [(Double, UInt64)] = []
        let seconds = max(1, Int(ProcessInfo.processInfo.environment["VOXSTUDIO_AGENT_STRESS_SECONDS"] ?? "30") ?? 30)
        let clock = ContinuousClock()
        let started = clock.now
        var tickNumber = 0
        while started.duration(to: clock.now) < .seconds(seconds) {
            let tick = clock.now
            try await Task.sleep(for: .milliseconds(100))
            let elapsed = started.duration(to: clock.now).agentLayoutSeconds
            // Alternate growing, complete/collapsed and cancelled rows for the
            // first half. Keep the final waiting state stable for leak checks.
            if elapsed < Double(seconds) / 2, tickNumber.isMultiple(of: 4) {
                let completed = tickNumber.isMultiple(of: 8)
                service.messages = stressMessages(saved.messages, round: tickNumber, complete: completed)
                service.rebuildToolResultIndex()
                if completed { service.cancel() } else { service.isStreaming = true }
            }
            if elapsed >= Double(seconds) / 2, !service.isStreaming {
                service.messages = stressMessages(saved.messages, round: tickNumber, complete: false)
                service.rebuildToolResultIndex()
                service.isStreaming = true
            }
            settleVisibleLayout(host)
            let delay = max(0, tick.duration(to: clock.now).agentLayoutSeconds - 0.1)
            maximumDelay = max(maximumDelay, delay)
            #expect(delay < 0.5, "Main-thread heartbeat delay was \(delay) seconds")
            let memory = footprint()
            peak = max(peak, memory)
            samples.append((elapsed, memory))
            tickNumber += 1
        }
        #expect(peak < baseline + 200 * 1024 * 1024)
        if let stable = samples.first(where: { $0.0 >= Double(seconds) * 2 / 3 }), let end = samples.last {
            #expect(end.1 < stable.1 + 50 * 1024 * 1024)
        }
        let stopped = clock.now
        service.cancel()
        settleVisibleLayout(host)
        #expect(stopped.duration(to: clock.now) < .milliseconds(500))
        #expect(!service.isStreaming)
        print("Agent layout stress seconds=\(seconds) baseline_mb=\(baseline / 1024 / 1024) peak_mb=\(peak / 1024 / 1024) worst_heartbeat_delay_ms=\(Int(maximumDelay * 1000))")
    }

    private func incidentHistory() throws -> ChatSession {
        if let path = ProcessInfo.processInfo.environment["VOXSTUDIO_AGENT_LAYOUT_FIXTURE"] {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(ChatSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            #expect(!snapshot.messages.isEmpty)
            print("Agent layout replay saved_messages=\(snapshot.messages.count)")
            return snapshot
        }
        let toolID = "saved-import"
        return ChatSession(title: "Controlled product demo history", messages: [
            AgentMessage(role: .user, blocks: [.text("Import the source recordings, confirm durations, and wait for the editing brief.")]),
            AgentMessage(role: .assistant, blocks: [.toolUse(id: toolID, name: "get_media", inputJSON: "{}")]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseId: toolID, content: [.text("{\"duration\":81.0}")], isError: false)]),
            AgentMessage(role: .assistant, blocks: [.text("The sources are ready. I will wait for your editing brief.")])
        ])
    }

    private func install(_ snapshot: ChatSession, in service: AgentService) {
        var session = snapshot
        session.isOpen = true
        service.sessions = [session]
        service.currentSessionId = session.id
        service.messages = session.messages
        service.rebuildToolResultIndex()
        service.onSessionsChanged = nil
    }

    private func stressMessages(_ saved: [AgentMessage], round: Int, complete: Bool) -> [AgentMessage] {
        let toolID = "stress-tool-\(round)"
        return saved + [
            AgentMessage(role: .user, blocks: [.text(longEditingBrief)]),
            AgentMessage(role: .assistant, blocks: [
                reasoning(summary: String(repeating: "Verify the clip boundaries. ", count: complete ? 1 : 80), complete: complete, round: round),
                .text(complete ? longAnswer : "Checking the timeline and source intervals…"),
                .toolUse(id: toolID, name: "inspect_timeline", inputJSON: "{\"round\":\(round)}")
            ]),
            AgentMessage(role: .user, blocks: [.toolResult(toolUseId: toolID, content: [.text("{\"ok\":true}")], isError: false)])
        ]
    }

    private func reasoning(summary: String, complete: Bool, round: Int) -> AgentContentBlock {
        .openAIReasoning(summary: summary, encryptedContent: complete ? "complete" : "", itemID: "reasoning-\(round)", model: .defaultModel)
    }

    private func textContent(_ message: AgentMessage) -> String {
        message.blocks.compactMap { if case let .text(text) = $0 { return text }; return nil }.joined()
    }

    private var longEditingBrief: String {
        """
        Create a polished 1920x1080 30fps VoxStudio product demo in the active empty timeline.
        Import /tmp/voxstudio-layout-fixtures/screenshots/transcript-dark.png and /tmp/voxstudio-layout-fixtures/screenshots/voiceover-dark.png and /tmp/voxstudio-layout-fixtures/demo/voxstudio-demo-voiceover.wav.
        The 37.228-second narration must start at timeline zero. Keep natural pace and mute all original screen-recording audio. Assemble visuals in this order using source seconds: 0–8 transcript-dark.png; 8–14 first recording source 47–53; 14–16 second recording source 64.8–66.8; 16–23 first recording source 55–62; 23–28 voiceover-dark.png; 28–32 first recording source 72.8–76.8; 32–39 transcript-dark.png.
        Use clean dark backgrounds, fully legible screenshots and recordings, and preserve aspect ratio. Add short white and indigo lower-third labels: 0–8 'VoxStudio / From recording to ready'; 8–14 'Editable transcripts. Connected subtitles.'; 14–16 'Find the moment that matters.'; 16–23 'Edit with AI. Stay in control.'; 23–28 'Your script. A voice that fits.'; 28–32 'Refine. Export. Share.'; 32–39 'Create your next story. / voxstudio.me/mac'. Use a subtle fade-in and soft shadow or dark title background. Verify frame intervals and narration placement before completing.
        """ + "\n" + String(repeating: "Preserve the original source files and verify every timeline interval against its source range. ", count: 18)
    }

    private var longAnswer: String {
        "# Timeline verification\n\n" + (0..<18).map {
            "- Section \($0): the source interval is correctly placed and the narration remains aligned."
        }.joined(separator: "\n") + "\n\n| Item | Result |\n|---|---|\n| Narration | 37.228 seconds at timeline zero |\n| Original audio | Muted |\n\n```json\n{\"width\":1920,\"height\":1080,\"fps\":30}\n```"
    }

    private func makeHost(_ editor: EditorViewModel, width: CGFloat) -> (NSWindow, NSHostingController<AnyView>) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: AnyView(AgentPanelView().environment(editor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 780),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.frame = window.contentLayoutRect
        window.orderFront(nil)
        return (window, host)
    }

    private func settleVisibleLayout(_ host: NSHostingController<AnyView>) {
        let started = ContinuousClock().now
        host.view.layoutSubtreeIfNeeded()
        // The incident occurred in a run-loop observer, so layoutSubtreeIfNeeded
        // alone is not a sufficient regression exercise.
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        #expect(started.duration(to: ContinuousClock().now) < .milliseconds(500))
    }

    private func waitForBottom(in host: NSHostingController<AnyView>) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var atBottom = false
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            settleVisibleLayout(host)
            if let scroll = chatScrollViews(in: host.view).max(by: { $0.bounds.height < $1.bounds.height }),
               let document = scroll.documentView {
                atBottom = document.bounds.maxY - scroll.documentVisibleRect.maxY <= 48
            }
        } while !atBottom && clock.now < deadline
        #expect(atBottom, "The latest assistant content must remain visible after growth, completion, or a session switch")
        try #require(atBottom)
    }

    private func chatScrollViews(in view: NSView) -> [NSScrollView] {
        let current: [NSScrollView]
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView), scroll.bounds.height > 80 {
            current = [scroll]
        } else { current = [] }
        return current + view.subviews.flatMap { chatScrollViews(in: $0) }
    }

    private func findInputTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable { return text }
        return view.subviews.lazy.compactMap { findInputTextView(in: $0) }.first
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
    var agentLayoutSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
