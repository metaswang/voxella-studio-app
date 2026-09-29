import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class KnowledgeBaseController {
    private static let localResourcesTipID = "knowledge-local-resources"
    var selectedScope: KnowledgeQAScope = .all
    /// Ordered multi-select (empty when scope is `.all`).
    var selectedSessionIDs: [UUID] = []
    var selectionAnchorID: UUID?
    var listQuery = ""
    var typeFilter: KnowledgeSourceType = .all
    var indexFilter: KnowledgeIndexFilter = .all
    var originFilter: KnowledgeOriginFilter = .all
    /// Default lists sources with content; Show all also includes metadata-only sources.
    var showAllSessions = false

    var conversation: KnowledgeConversation?
    var messages: [KnowledgeMessage] = []
    var draft = ""
    var isAnswering = false
    var statusText: String?
    var errorMessage: String?
    var accessBlockedMessage: String?
    var answerBlockedMessage: String?
    var answerRecoveryActions: [KnowledgeRecoveryAction] = []
    var pendingQuery: String?
    var modelPlan: LocalModelInstallPlan = .knowledgeQAPlan(
        answerModelID: nil,
        includeReranker: false,
        isInstalled: { _ in true }
    )
    var isPreparingModels = false
    var showModelGate = false
    var transcriptSessionID: UUID?
    var transcriptTarget: KnowledgeTranscriptTarget?
    var isClearingHistory = false
    var isLoadingSummaryForSessionID: UUID?

    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var clearHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var clearHistoryGeneration = UUID()
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private let chatStore: KnowledgeChatStore
    @ObservationIgnored private let answerProvider: @Sendable (KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent>
    @ObservationIgnored private let availabilityProvider: () -> KnowledgeAnswerAvailability
    @ObservationIgnored private let modelPlanProvider: (() -> LocalModelInstallPlan)?
    @ObservationIgnored private var activeAssistantID: UUID?

    init(
        chatStore: KnowledgeChatStore = .shared,
        answerProvider: @escaping @Sendable (KnowledgeQARequest) -> AsyncStream<KnowledgeAnswerEvent> = {
            KnowledgeQAService().answer($0)
        },
        availabilityProvider: @escaping () -> KnowledgeAnswerAvailability = { .current() },
        modelPlanProvider: (() -> LocalModelInstallPlan)? = nil
    ) {
        self.chatStore = chatStore
        self.answerProvider = answerProvider
        self.availabilityProvider = availabilityProvider
        self.modelPlanProvider = modelPlanProvider
    }
    private let models = LocalModelManager.shared

    var rows: [KnowledgeListRow] {
        let signedIn = AccountService.shared.isSignedIn
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: signedIn)
        let uiOrigins = originFilter.origins
        let effective: Set<KnowledgeSourceOrigin>
        if let uiOrigins {
            let intersection = uiOrigins.intersection(allowed)
            effective = intersection.isEmpty ? [] : intersection
        } else {
            effective = allowed
        }
        let sessions = WorkbenchStore.shared.sessions
            .filter { showAllSessions || Self.isP0Searchable($0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        let mapped = sessions.map(Self.makeRow(from:))
        return KnowledgeListQuery.filterRows(
            mapped,
            typeFilter: typeFilter,
            indexFilter: indexFilter,
            originFilter: originFilter,
            allowedOrigins: effective,
            query: listQuery
        )
    }

    /// P0: searchable ≈ has transcript or other usable result. SessionIndex flags are P1.
    static func isP0Searchable(_ session: WorkbenchSession) -> Bool {
        KnowledgeListRow.p0IsSearchable(
            hasTranscript: session.transcript != nil,
            hasUsableResult: session.hasUsableResult
        )
    }

    static func makeRow(from session: WorkbenchSession) -> KnowledgeListRow {
        // P0 "indexed" approximation: transcript / searchable result present.
        // Do not read SessionIndexStore.lexicalReady / embeddingReady here (P1).
        let searchable = isP0Searchable(session)
        let origin = KnowledgeSourceOrigin.resolve(
            isCloudStorage: session.storage == .cloud,
            hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly
        )
        return KnowledgeListRow(
            id: session.id,
            title: session.title.isEmpty ? L10n.string("Untitled session") : session.title,
            sessionType: session.sessionType,
            sourceType: KnowledgeSourceType.from(sessionType: session.sessionType),
            sourceOrigin: origin,
            modifiedAt: session.modifiedAt,
            duration: session.duration,
            lexicalReady: searchable,
            embeddingReady: false,
            hasTranscript: searchable
        )
    }

    var indexedSessionCount: Int {
        rows.filter(\.isIndexed).count
    }

    var scopeTitle: String {
        switch selectedScope {
        case .all:
            return L10n.string("All knowledge")
        case let .session(id):
            return titleForSession(id)
        case let .sessions(ids):
            return L10n.format("%@ sessions selected", ids.count)
        }
    }

    func titleForSession(_ id: UUID) -> String {
        rows.first(where: { $0.id == id })?.title
            ?? WorkbenchStore.shared.sessions.first(where: { $0.id == id })?.title
            ?? L10n.string("Session")
    }

    func isSessionSelected(_ id: UUID) -> Bool {
        selectedSessionIDs.contains(id)
    }

    var availableSessionCount: Int {
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(
            isSignedIn: AccountService.shared.isSignedIn, uiFilter: originFilter.origins
        )
        return WorkbenchStore.shared.sessions
            .filter {
                allowed.contains(
                    KnowledgeSourceOrigin.resolve(
                        isCloudStorage: $0.storage == .cloud,
                        hasRemoteSessionID: $0.remoteSessionID != nil || $0.isRemoteOnly
                    )
                )
            }
            .count
    }

    func isSessionVisibleForCurrentAuth(_ id: UUID) -> Bool {
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(
            isSignedIn: AccountService.shared.isSignedIn
        )
        if let row = row(for: id) {
            return allowed.contains(row.sourceOrigin)
        }
        guard let session = WorkbenchStore.shared.sessions.first(where: { $0.id == id }) else {
            return false
        }
        let origin = KnowledgeSourceOrigin.resolve(
            isCloudStorage: session.storage == .cloud,
            hasRemoteSessionID: session.remoteSessionID != nil || session.isRemoteOnly
        )
        return allowed.contains(origin)
    }

    var isSessionVisibleForCurrentAuth: Bool {
        switch selectedScope {
        case .all:
            return true
        case let .session(id):
            return isSessionVisibleForCurrentAuth(id)
        case let .sessions(ids):
            return ids.contains { isSessionVisibleForCurrentAuth($0) }
        }
    }

    func row(for id: UUID) -> KnowledgeListRow? {
        if let row = rows.first(where: { $0.id == id }) { return row }
        guard let session = WorkbenchStore.shared.sessions.first(where: { $0.id == id }) else { return nil }
        return Self.makeRow(from: session)
    }

    var selectedRow: KnowledgeListRow? {
        guard case let .session(id) = selectedScope else { return nil }
        return row(for: id)
    }

    var selectedQAAbleCount: Int {
        selectedSessionIDs.filter { id in
            isSessionVisibleForCurrentAuth(id) && row(for: id) != nil
        }.count
    }

    var canAskCurrentScope: Bool {
        switch selectedScope {
        case .all:
            return true
        case .session:
            guard isSessionVisibleForCurrentAuth else { return false }
            return selectedRow != nil
        case .sessions:
            return selectedSessionIDs.contains { isSessionVisibleForCurrentAuth($0) }
        }
    }

    var qaBlockedMessage: String? {
        guard !canAskCurrentScope else { return nil }
        switch selectedScope {
        case .all:
            return nil
        case .session:
            if !isSessionVisibleForCurrentAuth {
                return L10n.string("Sign in to ask about this cloud session.")
            }
            return L10n.string("This session has no transcript yet. Transcribe it first to ask questions.")
        case .sessions:
            if selectedSessionIDs.contains(where: { !isSessionVisibleForCurrentAuth($0) })
                && selectedQAAbleCount == 0
            {
                return L10n.string("Sign in to ask about the selected cloud sessions.")
            }
            return L10n.string("None of the selected sessions have a transcript yet. Transcribe at least one to ask.")
        }
    }

    var needsModelDownload: Bool {
        !modelPlan.missingItems.isEmpty
    }

    var isPreparingKnowledgeModels: Bool {
        isPreparingModels || models.isPreparing(modelPlan)
    }

    var downloadAskLabel: String {
        L10n.string(isPreparingKnowledgeModels ? "Preparing…" : "Download and ask")
    }

    var needsModelLicenseAcceptance: Bool {
        modelPlan.missingItems.contains {
            $0.requiresLicenseAcceptance && !models.isLicenseAccepted($0.id)
        }
    }

    var scopeSubtitle: String {
        switch selectedScope {
        case .all:
            if WorkbenchStore.shared.isHydrating {
                return L10n.string("Loading saved sessions…")
            }
            let count = availableSessionCount
            return L10n.format(
                count == 1 ? "Ask across %@ session" : "Ask across %@ sessions",
                count
            )
        case .session:
            if let row = selectedRow, !row.hasSearchableContent {
                return L10n.string("Ask about available metadata and summaries")
            }
            return L10n.string("Fast QA for this session only")
        case let .sessions(ids):
            let qaAble = selectedQAAbleCount
            let skipped = ids.count - qaAble
            if qaAble == 0 {
                return L10n.string("No available sources in selection")
            }
            if skipped > 0 {
                return L10n.format(
                    qaAble == 1
                        ? "Ask across %@ selected session (%@ skipped)"
                        : "Ask across %@ selected sessions (%@ skipped)",
                    qaAble,
                    skipped
                )
            }
            return L10n.format(
                qaAble == 1 ? "Ask across %@ selected session" : "Ask across %@ selected sessions",
                qaAble
            )
        }
    }

    func onAppear() {
        refreshAccessGate()
        if !AccountService.shared.isSignedIn, originFilter == .cloud {
            originFilter = .all
        }
        refreshModelPlan()
        Task { await loadConversation(for: selectedScope) }
    }

    func setOriginFilter(_ filter: KnowledgeOriginFilter) {
        guard AccountService.shared.isSignedIn || filter != .cloud else { return }
        originFilter = filter
    }

    func refreshModelPlan() {
        modelPlan = modelPlanProvider?() ?? KnowledgeQAModelPolicy.currentPlan(models: models)
        if !needsModelDownload, !isPreparingKnowledgeModels {
            WorkbenchTipCenter.shared.hide(id: Self.localResourcesTipID)
        }
        flushPendingQueryIfNeeded()
    }

    func syncModelPlan(_ plan: LocalModelInstallPlan) {
        modelPlan = modelPlanProvider?() ?? plan
        if !needsModelDownload, !isPreparingKnowledgeModels {
            WorkbenchTipCenter.shared.hide(id: Self.localResourcesTipID)
        }
        flushPendingQueryIfNeeded()
    }

    private func showLocalResourcesTip(_ message: String) {
        WorkbenchTipCenter.shared.update(
            WorkbenchTip(
                id: Self.localResourcesTipID,
                message: message,
                kind: .warning,
                actionLabel: L10n.string("Open Local Features"),
                action: .openLocalFeatures,
                autoDismiss: false
            )
        )
    }

    func refreshAccessGate() {
        let availability = availabilityProvider()
        accessBlockedMessage = availability == .localAccessRequired ? availability.message : nil
        answerBlockedMessage = availability == .localAccessRequired ? nil : availability.message
        answerRecoveryActions = availability.recoveryActions
    }

    func selectAll() {
        applyScope(.all, selectedIDs: [], anchor: nil)
    }

    func selectSession(_ id: UUID) {
        handleSessionClick(id, forceReplace: true)
    }

    func moveListSelection(by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        let itemCount = rows.count + 1
        guard itemCount > 0 else { return false }

        let currentIndex: Int = switch selectedScope {
        case .all:
            0
        case let .session(id):
            rows.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        case let .sessions(ids):
            ids.last.flatMap { id in rows.firstIndex(where: { $0.id == id }) }.map { $0 + 1 } ?? 0
        }
        let nextIndex = min(itemCount - 1, max(0, currentIndex + delta))
        if nextIndex == 0 {
            selectAll()
        } else if rows.indices.contains(nextIndex - 1) {
            selectSession(rows[nextIndex - 1].id)
        }
        return true
    }

    func openSelectedTranscript() -> Bool {
        let id: UUID?
        switch selectedScope {
        case .all:
            id = nil
        case let .session(sessionID):
            id = sessionID
        case let .sessions(ids):
            id = ids.last
        }
        guard let id else { return false }
        openTranscript(for: id)
        return transcriptSessionID == id
    }

    func openTranscript(for id: UUID, target: KnowledgeTranscriptTarget? = nil) {
        guard let session = session(for: id), KnowledgeTranscriptMaterial.displayTranscript(for: session) != nil else { return }
        transcriptSessionID = id
        transcriptTarget = target
    }

    func openCitation(_ ref: KnowledgeSourceRef) {
        CitationResolver.open(ref, in: self)
    }

    func closeTranscript() {
        transcriptSessionID = nil
        transcriptTarget = nil
    }

    func session(for id: UUID) -> WorkbenchSession? {
        WorkbenchStore.shared.sessions.first(where: { $0.id == id })
    }

    func openAppSession(for id: UUID) {
        guard session(for: id) != nil else { return }
        WorkbenchStore.shared.openSession(id)
    }

    /// Loads an existing session summary, generating it through the same
    /// Workbench enrichment path when the session has no persisted summary.
    /// The result is inserted directly as an assistant reply so summary cards
    /// never masquerade as a draft question.
    func showSummary(for sessionID: UUID) {
        guard !isAnswering, session(for: sessionID) != nil else { return }

        let scope = selectedScope
        let requestID = UUID()
        answerTask?.cancel()
        activeRequestID = requestID
        isAnswering = true
        statusText = L10n.string("Loading summary…")
        errorMessage = nil
        isLoadingSummaryForSessionID = sessionID
        answerTask = Task { [weak self] in
            await self?.loadAndShowSummary(
                for: sessionID,
                scope: scope,
                requestID: requestID
            )
        }
    }

    func clearHistory() {
        guard !isClearingHistory else { return }
        guard let conversationID = conversation?.id else {
            messages = []
            return
        }

        // Clearing history invalidates any in-flight answer before the store
        // operation starts, so late events cannot repopulate the cleared UI.
        activeRequestID = nil
        answerTask?.cancel()
        answerTask = nil
        isAnswering = false
        statusText = nil
        isClearingHistory = true
        errorMessage = nil
        clearHistoryTask?.cancel()
        let generation = UUID()
        let scope = selectedScope
        clearHistoryGeneration = generation
        loadGeneration = UUID()
        let chatStore = chatStore
        clearHistoryTask = Task { [weak self] in
            do {
                try await chatStore.clear(conversationID: conversationID)
                guard let self, self.clearHistoryGeneration == generation else { return }
                if !Task.isCancelled, self.selectedScope == scope, self.conversation?.id == conversationID {
                    self.loadGeneration = UUID()
                    self.messages = []
                }
                self.isClearingHistory = false
                self.clearHistoryTask = nil
            } catch is CancellationError {
                guard let self, self.clearHistoryGeneration == generation else { return }
                self.isClearingHistory = false
                self.clearHistoryTask = nil
            } catch {
                guard let self, self.clearHistoryGeneration == generation else { return }
                self.isClearingHistory = false
                self.clearHistoryTask = nil
                if self.selectedScope == scope, self.conversation?.id == conversationID {
                    self.errorMessage = KnowledgeUserFacingCopy.message(for: error)
                }
            }
        }
    }

    /// Click / ⌘-click / ⇧-click selection (no checkboxes).
    func handleSessionClick(_ id: UUID, forceReplace: Bool = false) {
        let flags = NSEvent.modifierFlags
        let command = !forceReplace && flags.contains(.command)
        let shift = !forceReplace && flags.contains(.shift)

        var next = selectedSessionIDs
        var anchor = selectionAnchorID

        if command {
            if let index = next.firstIndex(of: id) {
                next.remove(at: index)
            } else {
                next.append(id)
            }
            anchor = id
        } else if shift {
            let ordered = rows.map(\.id)
            let anchorID = anchor ?? next.last ?? id
            if let a = ordered.firstIndex(of: anchorID),
               let b = ordered.firstIndex(of: id)
            {
                let lo = min(a, b)
                let hi = max(a, b)
                next = Array(ordered[lo...hi])
            } else {
                next = [id]
                anchor = id
            }
        } else {
            next = [id]
            anchor = id
        }

        let scope = KnowledgeQAScope.fromSelection(next)
        applyScope(scope, selectedIDs: scope.sessionIDs, anchor: anchor)
    }

    private func applyScope(
        _ scope: KnowledgeQAScope,
        selectedIDs: [UUID],
        anchor: UUID?
    ) {
        let scopeChanged = selectedScope != scope
        selectedSessionIDs = selectedIDs
        selectionAnchorID = anchor
        guard scopeChanged else { return }
        selectedScope = scope
        activeRequestID = nil
        answerTask?.cancel()
        prepareTask?.cancel()
        isAnswering = false
        statusText = nil
        pendingQuery = nil
        isLoadingSummaryForSessionID = nil
        Task { await loadConversation(for: scope) }
    }

    func loadConversation(for scope: KnowledgeQAScope) async {
        let currentGeneration = UUID()
        loadGeneration = currentGeneration
        activeRequestID = nil
        answerTask?.cancel()
        isAnswering = false
        statusText = nil
        errorMessage = nil
        do {
            let conversation = try await chatStore.conversation(for: scope)
            let messages = try await chatStore.messages(for: conversation.id)
            guard loadGeneration == currentGeneration else { return }
            self.conversation = conversation
            self.messages = messages
            self.flushPendingQueryIfNeeded()
        } catch {
            guard loadGeneration == currentGeneration else { return }
            self.errorMessage = KnowledgeUserFacingCopy.message(for: error)
        }
    }

    func setShowAllSessions(_ value: Bool) {
        guard showAllSessions != value else { return }
        showAllSessions = value
        if !value {
            hideUnlistedSelectionIfNeeded()
        }
    }

    func hideUnlistedSelectionIfNeeded() {
        let visible = Set(rows.map(\.id))
        let remaining = selectedSessionIDs.filter { visible.contains($0) }
        if remaining.count != selectedSessionIDs.count {
            let scope = KnowledgeQAScope.fromSelection(remaining)
            applyScope(scope, selectedIDs: scope.sessionIDs, anchor: selectionAnchorID)
        }
    }

    /// Send / Voice-final entry. Tools use the capabilities available to this scope.
    func send() {
        send(query: draft)
    }

    func send(query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPreparingKnowledgeModels
        else { return }
        refreshAccessGate()
        guard accessBlockedMessage == nil else { return }
        guard answerBlockedMessage == nil else { return }
        guard canAskCurrentScope else {
            errorMessage = qaBlockedMessage
            return
        }

        if isAnswering { cancelAnswer() }

        // Reserve the request slot before model preparation or task creation;
        // repeated submissions cannot replace the accepted round silently.
        activeRequestID = UUID()
        pendingQuery = text
        errorMessage = nil
        flushPendingQueryIfNeeded()
    }

    func downloadAndAsk() {
        let text = (pendingQuery ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        refreshAccessGate()
        guard accessBlockedMessage == nil, answerBlockedMessage == nil else { return }
        activeRequestID = activeRequestID ?? UUID()
        pendingQuery = text
        refreshModelPlan()
        guard needsModelDownload else {
            flushPendingQueryIfNeeded()
            return
        }
        if needsModelLicenseAcceptance {
            models.presentManager()
            showModelGate = true
            return
        }
        showModelGate = true
        isPreparingModels = true
        showLocalResourcesTip(L10n.string("Preparing local search resources…"))
        errorMessage = nil
        prepareTask?.cancel()
        prepareTask = Task { await ensureModelsThenAsk() }
    }

    func cancelModelPreparation() {
        prepareTask?.cancel()
        prepareTask = nil
        isPreparingModels = false
        activeRequestID = nil
        showLocalResourcesTip(L10n.string("Local search preparation is paused. Resume from Local Features when you’re ready."))
        // Keep pendingQuery; do not auto-ask after cancel.
    }

    func cancelAnswer() {
        if let assistantID = activeAssistantID,
           let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].isStreaming {
            if messages[index].content.isEmpty {
                messages.remove(at: index)
            } else {
                messages[index].isStreaming = false
                let partial = messages[index]
                let store = chatStore
                Task { try? await store.append(partial) }
            }
        }
        if let requestID = activeRequestID {
            Log.knowledge.notice("chat cancelled request_id=\(requestID.uuidString)")
        }
        activeRequestID = nil
        activeAssistantID = nil
        answerTask?.cancel()
        answerTask = nil
        isAnswering = false
        statusText = nil
        isLoadingSummaryForSessionID = nil
    }

    private func ensureModelsThenAsk() async {
        do {
            try await models.ensureKnowledgeQAModels(
                answerModelID: KnowledgeQAModelPolicy.localAnswerModelID,
                includeReranker: KnowledgeQAModelPolicy.includeReranker
            )
            isPreparingModels = false
            refreshModelPlan()
            WorkbenchTipCenter.shared.hide(id: Self.localResourcesTipID)
        } catch is CancellationError {
            isPreparingModels = false
        } catch {
            isPreparingModels = false
            Log.search.error("knowledge local resource preparation failed: \(error.localizedDescription)")
            errorMessage = L10n.string("Local search resources couldn’t be prepared. Try again.")
            showLocalResourcesTip(L10n.string("Local search resources couldn’t be prepared. Try again."))
            showModelGate = true
        }
    }

    private func flushPendingQueryIfNeeded() {
        guard KnowledgeQAReadyGate.shouldFlushPending(
            pendingQuery: pendingQuery,
            missingCount: 0,
            isAnswering: isAnswering
        ) else { return }
        refreshAccessGate()
        guard accessBlockedMessage == nil, answerBlockedMessage == nil else {
            pendingQuery = nil
            return
        }
        let text = pendingQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pinnedScope = selectedScope
        guard let pinnedConversationID = conversation?.id else { return }
        pendingQuery = nil
        showModelGate = false
        isPreparingModels = false
        draft = ""
        errorMessage = nil
        let requestID = activeRequestID ?? UUID()
        activeRequestID = requestID
        isAnswering = true
        statusText = L10n.string("Starting…")
        answerTask?.cancel()
        answerTask = Task {
            await ask(
                text,
                scope: pinnedScope,
                conversationID: pinnedConversationID,
                requestID: requestID
            )
        }
    }

    private func ask(_ text: String) async {
        guard let conversation else {
            await loadConversation(for: selectedScope)
            guard self.conversation != nil else { return }
            await ask(text)
            return
        }
        let pinnedScope = selectedScope
        let requestID = UUID()
        activeRequestID = requestID
        isAnswering = true
        statusText = L10n.string("Starting…")
        await ask(text, scope: pinnedScope, conversationID: conversation.id, requestID: requestID)
    }

    private func ask(
        _ text: String,
        scope: KnowledgeQAScope,
        conversationID: UUID,
        requestID: UUID
    ) async {
        refreshAccessGate()
        guard accessBlockedMessage == nil, answerBlockedMessage == nil,
              conversation?.id == conversationID, selectedScope == scope,
              activeRequestID == requestID
        else { return }
        isAnswering = true
        statusText = L10n.string("Starting…")
        defer {
            if activeRequestID == requestID {
                activeRequestID = nil
                activeAssistantID = nil
                answerTask = nil
                isAnswering = false
                statusText = nil
            }
        }
        Log.knowledge.notice("chat started request_id=\(requestID.uuidString)")

        let userMessage = KnowledgeMessage(
            conversationID: conversationID,
            role: .user,
            content: text
        )
        messages.append(userMessage)
        do {
            try await chatStore.append(userMessage)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            errorMessage = KnowledgeUserFacingCopy.message(for: error)
        }
        guard !Task.isCancelled,
              conversation?.id == conversationID,
              selectedScope == scope,
              activeRequestID == requestID
        else {
            return
        }

        let assistantID = UUID()
        var assistant = KnowledgeMessage(
            id: assistantID,
            conversationID: conversationID,
            role: .assistant,
            content: "",
            isStreaming: true
        )
        messages.append(assistant)
        activeAssistantID = assistantID

        let history = messages.filter { $0.id != assistantID && $0.id != userMessage.id }
        let request = KnowledgeQARequest(
            queryText: text,
            conversationID: conversationID,
            scope: scope,
            originFilter: originFilter.origins,
            history: history,
            requestID: requestID
        )

        var receivedTerminalEvent = false
        let stream = answerProvider(request)
        do {
            for await event in stream {
                try Task.checkCancellation()
                guard conversation?.id == conversationID,
                      selectedScope == scope, activeRequestID == requestID else { break }
                switch event {
                case let .status(status):
                    if statusText != status { statusText = status }
                case let .delta(chunk):
                    assistant.content += chunk
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .citations(refs):
                    assistant.citations = refs
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .recoveryActions(actions):
                    assistant.recoveryActions = actions
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .finished(finalText):
                    receivedTerminalEvent = true
                    assistant.content = finalText
                    assistant.isStreaming = false
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .clarification(question):
                    receivedTerminalEvent = true
                    assistant.content = question
                    assistant.citations = []
                    assistant.isStreaming = false
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .failed(message):
                    receivedTerminalEvent = true
                    if assistant.content.isEmpty { assistant.content = message }
                    assistant.isStreaming = false
                    upsertAssistant(assistant, conversationID: conversationID)
                    errorMessage = message
                }
                if receivedTerminalEvent {
                    // Consume and persist one terminal result. A producer may incorrectly
                    // send another result or keep the stream open after completion.
                    activeAssistantID = nil
                    do { try await chatStore.append(assistant) }
                    catch {
                        if activeRequestID == requestID {
                            errorMessage = KnowledgeUserFacingCopy.message(for: error)
                        }
                    }
                    Log.knowledge.notice("chat finished chars=\(assistant.content.count) request_id=\(requestID.uuidString)")
                    break
                }
            }
            if !receivedTerminalEvent, !Task.isCancelled,
               activeRequestID == requestID,
               conversation?.id == conversationID, selectedScope == scope {
                messages.removeAll { $0.id == assistantID }
                errorMessage = L10n.string("Answer stream ended before completion.")
            }
        } catch is CancellationError {
            if activeRequestID == requestID { cancelAnswer() }
        } catch {
            guard conversation?.id == conversationID,
                  selectedScope == scope, activeRequestID == requestID else { return }
            assistant.content = KnowledgeUserFacingCopy.message(for: error)
            assistant.isStreaming = false
            upsertAssistant(assistant, conversationID: conversationID)
            errorMessage = KnowledgeUserFacingCopy.message(for: error)
        }
    }

    private func upsertAssistant(_ message: KnowledgeMessage, conversationID: UUID) {
        guard conversation?.id == conversationID else { return }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func loadAndShowSummary(
        for sessionID: UUID,
        scope: KnowledgeQAScope,
        requestID: UUID
    ) async {
        defer {
            if activeRequestID == requestID {
                activeRequestID = nil
                answerTask = nil
                isAnswering = false
                statusText = nil
                isLoadingSummaryForSessionID = nil
            }
        }

        do {
            try await ensureConversationLoaded(for: scope)
            guard isCurrentRequest(requestID, scope: scope),
                  let conversationID = conversation?.id else { return }

            let summary = try await loadOrGenerateSummary(for: sessionID)
            guard isCurrentRequest(requestID, scope: scope) else { return }

            let message = KnowledgeMessage(
                conversationID: conversationID,
                role: .assistant,
                content: summary.markdown,
                citations: [summary.citation]
            )
            messages.append(message)
            try await chatStore.append(message)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentRequest(requestID, scope: scope) else { return }
            errorMessage = KnowledgeUserFacingCopy.message(for: error)
        }
    }

    private func ensureConversationLoaded(for scope: KnowledgeQAScope) async throws {
        guard conversation?.scope != scope else { return }
        let loadedConversation = try await chatStore.conversation(for: scope)
        try Task.checkCancellation()
        let loadedMessages = try await chatStore.messages(for: loadedConversation.id)
        try Task.checkCancellation()
        guard selectedScope == scope else { throw CancellationError() }
        conversation = loadedConversation
        messages = loadedMessages
    }

    private func loadOrGenerateSummary(for sessionID: UUID) async throws -> KnowledgeSummaryReply {
        if let cached = try await cachedSummary(for: sessionID) {
            return cached
        }

        statusText = L10n.string("Generating summary…")
        await WorkbenchStore.shared.ensureSummary(for: sessionID)

        // A summary task may already be running because the session was opened
        // from Recent. Give that task time to commit its result before showing
        // an error in chat.
        for _ in 0..<150 {
            try Task.checkCancellation()
            if let cached = try await cachedSummary(for: sessionID) {
                return cached
            }
            if let session = session(for: sessionID),
               session.summaryState == .failed
                || (session.summaryState == nil && Self.nonEmptyText(session.summaryMarkdown) == nil) {
                break
            }
            try await Task.sleep(for: .milliseconds(400))
        }

        throw KnowledgeSummaryError.unavailable
    }

    private func cachedSummary(for sessionID: UUID) async throws -> KnowledgeSummaryReply? {
        if let session = session(for: sessionID),
           let markdown = Self.nonEmptyText(session.summaryMarkdown) {
            return KnowledgeSummaryReply(
                markdown: markdown,
                citation: Self.summaryCitation(
                    sessionID: sessionID,
                    title: session.title,
                    markdown: markdown
                )
            )
        }

        let service = SessionIndexCoordinator.shared.searchService
        guard let indexed = try await service.sessionSummary(id: sessionID),
              let markdown = Self.nonEmptyText(indexed.markdown) else {
            return nil
        }
        return KnowledgeSummaryReply(
            markdown: markdown,
            citation: Self.summaryCitation(
                sessionID: sessionID,
                title: indexed.title,
                markdown: markdown
            )
        )
    }

    private func isCurrentRequest(_ requestID: UUID, scope: KnowledgeQAScope) -> Bool {
        activeRequestID == requestID && selectedScope == scope && !Task.isCancelled
    }

    private static func nonEmptyText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func summaryCitation(
        sessionID: UUID,
        title: String,
        markdown: String
    ) -> KnowledgeSourceRef {
        KnowledgeSourceRef(
            sourceID: sessionID.uuidString,
            sourceType: "sessionSummary",
            title: title.isEmpty ? "Untitled session" : title,
            uri: nil,
            page: nil,
            startTime: nil,
            endTime: nil,
            parentID: nil,
            chunkIndex: -2,
            language: nil,
            speaker: nil,
            snippet: markdown,
            matchText: nil
        )
    }

    func performRecoveryAction(_ action: KnowledgeRecoveryAction) {
        switch action {
        case .account:
            SettingsWindowController.shared.show(tab: .account)
        case .aiSettings:
            SettingsWindowController.shared.show(tab: .ai)
        }
    }
}

private struct KnowledgeSummaryReply {
    let markdown: String
    let citation: KnowledgeSourceRef
}

private enum KnowledgeSummaryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "No generated summary is available for this session yet."
    }
}
