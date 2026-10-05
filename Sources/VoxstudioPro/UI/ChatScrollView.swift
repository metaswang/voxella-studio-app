import SwiftUI

/// A stable scroll shell for growing conversations. Callers supply an eager
/// stack; its width comes from the viewport, never from measured SwiftUI state.
struct ChatScrollView<Update: Equatable, Content: View, ScrollAway: View>: View {
    let conversationID: UUID?
    let updateToken: Update
    let submittedMessageID: UUID?
    var horizontalInset: CGFloat = 0
    var maximumColumnWidth: CGFloat?
    @ViewBuilder let content: (CGFloat) -> Content
    @ViewBuilder let scrollAway: (@escaping () -> Void) -> ScrollAway

    @State private var follow = ChatScrollFollowState()
    @State private var scrollTask: Task<Void, Never>?
    @State private var scrollRequestID = UUID()

    var body: some View {
        GeometryReader { viewport in
            let inset = ChatScrollMetrics.normalizedInset(horizontalInset)
            let width = ChatScrollMetrics.contentWidth(
                viewportWidth: viewport.size.width,
                horizontalInset: inset,
                maximumColumnWidth: maximumColumnWidth
            )
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        content(width)
                            .frame(width: width)
                        Color.clear.frame(height: 1).id(ChatScrollAnchor.latest)
                    }
                    .frame(width: width)
                    .padding(.horizontal, inset)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    ChatScrollMetrics.isNearBottom(
                        contentHeight: geometry.contentSize.height,
                        offset: geometry.contentOffset.y,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { _, nearBottom in
                    // Content growth and programmatic scrolling must not write
                    // layout-derived values back into the view graph.
                    if follow.isUserScrolling, follow.followsLatest != nearBottom {
                        follow.updateGeometry(isNearBottom: nearBottom)
                    }
                }
                .onScrollPhaseChange { _, phase, context in
                    let userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    let geometry = context.geometry
                    if follow.isUserScrolling || userScrolling {
                        follow.updateScrollPhase(
                            isUserScrolling: userScrolling,
                            isNearBottom: ChatScrollMetrics.isNearBottom(
                                contentHeight: geometry.contentSize.height,
                                offset: geometry.contentOffset.y,
                                viewportHeight: geometry.containerSize.height
                            )
                        )
                    }
                    if userScrolling { cancelPendingScroll() }
                }
                .onChange(of: updateToken) { _, _ in
                    if follow.shouldFollowUpdates { scrollToLatest(using: proxy) }
                }
                .onChange(of: submittedMessageID) { previous, submitted in
                    guard let submitted, submitted != previous else { return }
                    follow.followLatest()
                    scrollToLatest(using: proxy)
                }
                .onChange(of: conversationID) { _, _ in
                    cancelPendingScroll()
                    follow.reset()
                    scrollToLatest(using: proxy)
                }
                .onChange(of: width) { _, _ in
                    if follow.shouldFollowUpdates { scrollToLatest(using: proxy) }
                }
                .onAppear { scrollToLatest(using: proxy) }
                .onDisappear { cancelPendingScroll() }
                .overlay(alignment: .bottomTrailing) {
                    if !follow.followsLatest {
                        scrollAway {
                            follow.followLatest()
                            scrollToLatest(using: proxy)
                        }
                    }
                }
            }
        }
    }

    private func cancelPendingScroll() {
        scrollTask?.cancel()
        scrollTask = nil
        scrollRequestID = UUID()
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        // Preserve the current frame's deadline while new deltas arrive. A
        // trailing debounce would never scroll during a sufficiently fast stream.
        guard scrollTask == nil else { return }
        let requestID = scrollRequestID
        scrollTask = Task { @MainActor in
            // Coalesce streaming updates and leave the current layout transaction
            // before positioning a concrete, permanently mounted sentinel.
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled, scrollRequestID == requestID else { return }
            scrollTask = nil
            guard follow.shouldFollowUpdates else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(ChatScrollAnchor.latest, anchor: .bottom) }
        }
    }
}

extension ChatScrollView where ScrollAway == EmptyView {
    init(
        conversationID: UUID?,
        updateToken: Update,
        submittedMessageID: UUID?,
        horizontalInset: CGFloat = 0,
        maximumColumnWidth: CGFloat? = nil,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.conversationID = conversationID
        self.updateToken = updateToken
        self.submittedMessageID = submittedMessageID
        self.horizontalInset = horizontalInset
        self.maximumColumnWidth = maximumColumnWidth
        self.content = content
        self.scrollAway = { _ in EmptyView() }
    }
}

private enum ChatScrollAnchor: Hashable { case latest }

/// User intent is independent of changing content heights and scroll animations.
struct ChatScrollFollowState {
    private(set) var followsLatest = true
    private(set) var isUserScrolling = false
    var shouldFollowUpdates: Bool { followsLatest && !isUserScrolling }

    mutating func updateGeometry(isNearBottom: Bool) {
        guard isUserScrolling else { return }
        followsLatest = isNearBottom
    }

    mutating func updateScrollPhase(isUserScrolling: Bool, isNearBottom: Bool) {
        if self.isUserScrolling || isUserScrolling { followsLatest = isNearBottom }
        self.isUserScrolling = isUserScrolling
    }

    mutating func followLatest() { followsLatest = true }

    mutating func reset() {
        followsLatest = true
        isUserScrolling = false
    }
}

enum ChatScrollMetrics {
    static func normalizedInset(_ inset: CGFloat) -> CGFloat {
        inset.isFinite ? max(0, inset) : 0
    }

    static func contentWidth(
        viewportWidth: CGFloat,
        horizontalInset: CGFloat,
        maximumColumnWidth: CGFloat? = nil
    ) -> CGFloat {
        let viewport = viewportWidth.isFinite ? max(1, viewportWidth) : 1
        let column = maximumColumnWidth.flatMap { $0.isFinite ? max(1, $0) : nil }
            .map { min(viewport, $0) } ?? viewport
        return max(1, column - normalizedInset(horizontalInset) * 2)
    }

    static func isNearBottom(contentHeight: CGFloat, offset: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentHeight - offset - viewportHeight <= 48
    }
}
