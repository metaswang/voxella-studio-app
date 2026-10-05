import AppKit
import Observation
import SwiftUI
import Testing
@testable import VoxstudioPro

@Suite("Shared chat scrolling", .serialized)
@MainActor
struct ChatScrollViewTests {
    @Test func growingContentDoesNotChangeTheUsersFollowIntent() {
        var follow = ChatScrollFollowState()
        follow.updateGeometry(isNearBottom: false)
        #expect(follow.shouldFollowUpdates)

        follow.updateScrollPhase(isUserScrolling: true, isNearBottom: false)
        #expect(!follow.followsLatest)
        #expect(!follow.shouldFollowUpdates)
        follow.updateScrollPhase(isUserScrolling: false, isNearBottom: false)
        follow.updateGeometry(isNearBottom: true)
        #expect(!follow.followsLatest)

        // A submitted question or the explicit latest button resumes following.
        follow.followLatest()
        #expect(follow.shouldFollowUpdates)
        follow.updateScrollPhase(isUserScrolling: true, isNearBottom: true)
        #expect(!follow.shouldFollowUpdates)
        follow.updateScrollPhase(isUserScrolling: false, isNearBottom: true)
        #expect(follow.shouldFollowUpdates)
    }

    @Test func changingConversationsClearsThePreviousScrollGesture() {
        var follow = ChatScrollFollowState()
        follow.updateScrollPhase(isUserScrolling: true, isNearBottom: false)
        follow.reset()
        #expect(follow.followsLatest)
        #expect(!follow.isUserScrolling)
        #expect(follow.shouldFollowUpdates)
    }

    @Test func contentWidthIsFiniteAndDependsOnlyOnTheViewport() {
        #expect(ChatScrollMetrics.contentWidth(viewportWidth: 360, horizontalInset: 20,
            maximumColumnWidth: 640) == 320)
        #expect(ChatScrollMetrics.contentWidth(viewportWidth: 1000, horizontalInset: 20,
            maximumColumnWidth: 640) == 600)
        #expect(ChatScrollMetrics.contentWidth(viewportWidth: 0, horizontalInset: 20) == 1)
        #expect(ChatScrollMetrics.contentWidth(viewportWidth: .infinity, horizontalInset: 20) == 1)
        #expect(ChatScrollMetrics.contentWidth(viewportWidth: 360, horizontalInset: .nan) == 360)
    }

    @Test func nativeLayoutKeepsTheColumnWidthStableWhileMessagesGrow() async throws {
        let probe = ChatScrollProbe()
        let (window, host) = makeHost(probe, width: 360)
        defer { window.close() }
        window.orderFront(nil)
        try await waitUntil {
            settleLayout(host)
            return findWidthProbe(in: host.view) != nil
        }
        for width in [CGFloat(360), 1000, 480, 360] {
            window.setContentSize(NSSize(width: width, height: 500))
            for turn in 0..<4 {
                probe.rows.append(String(repeating: "Message \(turn) wraps at the viewport width. ", count: 12))
                probe.revision += 1
                try await waitUntil {
                    settleLayout(host)
                    guard let measurement = findWidthProbe(in: host.view) else { return false }
                    let expected = ChatScrollMetrics.contentWidth(viewportWidth: width,
                        horizontalInset: 20, maximumColumnWidth: 640)
                    return abs(measurement.offeredWidth - expected) < 0.5
                        && abs(measurement.bounds.width - expected) < 0.5
                }
            }
        }
    }

    @Test func coalescedGrowthAndConversationChangesKeepTheConcreteBottomVisible() async throws {
        let probe = ChatScrollProbe()
        probe.rows = (0..<35).map { "Earlier message \($0): " + String(repeating: "completed text ", count: 12) }
        let (window, host) = makeHost(probe, width: 480)
        defer { window.close() }
        window.orderFront(nil)
        try await waitForBottom(host)
        for _ in 0..<12 {
            probe.rows.append(String(repeating: "Growing assistant response. ", count: 12))
            probe.revision += 1
        }
        try await waitForBottom(host)
        window.setContentSize(NSSize(width: 360, height: 500))
        try await waitForBottom(host)

        // Nil identifiers are supported, and a new conversation must supersede
        // any scroll queued for the old history.
        probe.conversationID = nil
        probe.submittedMessageID = UUID()
        probe.rows = ["New question", String(repeating: "A different conversation. ", count: 180)]
        probe.revision += 1
        try await waitForBottom(host)
        probe.conversationID = UUID()
        probe.rows.append(String(repeating: "Latest answer. ", count: 180))
        probe.revision += 1
        try await waitForBottom(host)
    }

    @Test func rapidContinuousDeltasScrollBeforeTheProducerFinishes() async throws {
        let probe = ChatScrollProbe()
        probe.rows = (0..<25).map { "Earlier message \($0): " + String(repeating: "completed text ", count: 12) }
        probe.rows.append("Streaming: ")
        let (window, host) = makeHost(probe, width: 480)
        defer { window.close() }
        window.orderFront(nil)
        try await waitForBottom(host)
        let scroll = try #require(findScrollView(in: host.view))
        let document = try #require(scroll.documentView)
        let initialHeight = document.bounds.height
        let initialVisibleBottom = scroll.documentVisibleRect.maxY
        probe.isProducing = true
        let stream = Task { @MainActor in
            defer { probe.isProducing = false }
            for _ in 0..<300 {
                guard !Task.isCancelled else { return }
                probe.rows[probe.rows.count - 1] += "streaming delta "
                probe.revision += 1
                // Updates arrive much faster than the scroll frame's deadline.
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
            }
        }
        defer { stream.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        try await waitUntil {
            settleLayout(host)
            return probe.isProducing
                && document.bounds.height > initialHeight + 100
                && scroll.documentVisibleRect.maxY > initialVisibleBottom + 100
                && document.bounds.maxY - scroll.documentVisibleRect.maxY <= 48
        }
        await stream.value
        try await waitForBottom(host)
    }

    private func makeHost(_ probe: ChatScrollProbe, width: CGFloat) -> (NSWindow, NSHostingController<ChatScrollHarness>) {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: ChatScrollHarness(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.frame = window.contentLayoutRect
        return (window, host)
    }

    private func settleLayout(_ host: NSHostingController<ChatScrollHarness>) {
        let started = ContinuousClock().now
        host.view.layoutSubtreeIfNeeded()
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        #expect(started.duration(to: ContinuousClock().now) < .milliseconds(500))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func waitForBottom(_ host: NSHostingController<ChatScrollHarness>) async throws {
        try await waitUntil {
            settleLayout(host)
            guard let scroll = findScrollView(in: host.view), let document = scroll.documentView else { return false }
            return document.bounds.maxY - scroll.documentVisibleRect.maxY <= 48
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    private func findWidthProbe(in view: NSView) -> ChatWidthProbeView? {
        if let probe = view as? ChatWidthProbeView { return probe }
        return view.subviews.lazy.compactMap { findWidthProbe(in: $0) }.first
    }
}

@Observable
@MainActor
private final class ChatScrollProbe {
    var conversationID: UUID? = UUID()
    var submittedMessageID: UUID?
    var revision = 0
    var rows: [String] = []
    var isProducing = false
}

private struct ChatScrollHarness: View {
    let probe: ChatScrollProbe

    var body: some View {
        ChatScrollView(conversationID: probe.conversationID, updateToken: probe.revision,
            submittedMessageID: probe.submittedMessageID, horizontalInset: 20, maximumColumnWidth: 640) { width in
            VStack(alignment: .leading, spacing: 12) {
                ChatWidthMeasurement(offeredWidth: width).frame(height: 1)
                ForEach(Array(probe.rows.enumerated()), id: \.offset) { _, text in
                    Text(verbatim: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 12)
        } scrollAway: { action in
            Button("Latest", action: action).padding(12)
        }
    }
}

private struct ChatWidthMeasurement: NSViewRepresentable {
    let offeredWidth: CGFloat

    func makeNSView(context: Context) -> ChatWidthProbeView {
        ChatWidthProbeView(frame: .zero)
    }

    func updateNSView(_ nsView: ChatWidthProbeView, context: Context) {
        nsView.offeredWidth = offeredWidth
    }
}

@MainActor
private final class ChatWidthProbeView: NSView {
    var offeredWidth: CGFloat = 0
}
