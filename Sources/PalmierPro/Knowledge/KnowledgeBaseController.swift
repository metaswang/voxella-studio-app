import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class KnowledgeBaseController {
    var selectedScope: KnowledgeQAScope = .all
    /// Ordered multi-select (empty when scope is `.all`).
    var selectedSessionIDs: [UUID] = []
    var selectionAnchorID: UUID?
    var listQuery = ""
    var typeFilter: KnowledgeSourceType = .all
    var indexFilter: KnowledgeIndexFilter = .all
    var originFilter: KnowledgeOriginFilter = .all
    /// Default hides empty/unindexed sessions. On: include them (grayed, not QA-able).
    var showAllSessions = false

    var conversation: KnowledgeConversation?
    var messages: [KnowledgeMessage] = []
    var draft = ""
    var isAnswering = false
    var statusText: String?
    var errorMessage: String?
    var accessBlockedMessage: String?
    var pendingQuery: String?
    var modelPlan: LocalModelInstallPlan = .knowledgeQAPlan(
        answerModelID: nil,
        includeReranker: false,
        isInstalled: { _ in true }
    )
    var isPreparingModels = false
    var showModelGate = false

    private var answerTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private let chatStore = KnowledgeChatStore.shared
    private var qaService = KnowledgeQAService()
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
            title: session.title.isEmpty ? "Untitled session" : session.title,
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
            return "All knowledge"
        case let .session(id):
            return titleForSession(id)
        case let .sessions(ids):
            return "\(ids.count) sessions selected"
        }
    }

    func titleForSession(_ id: UUID) -> String {
        rows.first(where: { $0.id == id })?.title
            ?? WorkbenchStore.shared.sessions.first(where: { $0.id == id })?.title
            ?? "Session"
    }

    func isSessionSelected(_ id: UUID) -> Bool {
        selectedSessionIDs.contains(id)
    }

    var searchableSessionCount: Int {
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(
            isSignedIn: AccountService.shared.isSignedIn
        )
        return WorkbenchStore.shared.sessions
            .filter(Self.isP0Searchable)
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
            isSessionVisibleForCurrentAuth(id) && (row(for: id)?.isQAAble ?? false)
        }.count
    }

    var canAskCurrentScope: Bool {
        switch selectedScope {
        case .all:
            return true
        case .session:
            guard isSessionVisibleForCurrentAuth else { return false }
            return selectedRow?.isQAAble ?? false
        case .sessions:
            return selectedQAAbleCount >= 1
        }
    }

    var qaBlockedMessage: String? {
        guard !canAskCurrentScope else { return nil }
        switch selectedScope {
        case .all:
            return nil
        case .session:
            if !isSessionVisibleForCurrentAuth {
                return "Sign in to ask about this cloud session."
            }
            return "This session has no transcript yet. Transcribe it first to ask questions."
        case .sessions:
            if selectedSessionIDs.contains(where: { !isSessionVisibleForCurrentAuth($0) })
                && selectedQAAbleCount == 0
            {
                return "Sign in to ask about the selected cloud sessions."
            }
            return "None of the selected sessions have a transcript yet. Transcribe at least one to ask."
        }
    }

    var needsModelDownload: Bool {
        !modelPlan.missingItems.isEmpty
    }

    var isPreparingKnowledgeModels: Bool {
        isPreparingModels || models.isPreparing(modelPlan)
    }

    var modelStatusText: String? {
        guard needsModelDownload else { return nil }
        if isPreparingKnowledgeModels {
            return "Preparing local search models…"
        }
        return "Local search model not ready (WeMM). Download before asking."
    }

    var downloadAskLabel: String {
        isPreparingKnowledgeModels ? "Preparing…" : "Download and ask"
    }

    var needsModelLicenseAcceptance: Bool {
        modelPlan.missingItems.contains {
            $0.requiresLicenseAcceptance && !models.isLicenseAccepted($0.id)
        }
    }

    var scopeSubtitle: String {
        switch selectedScope {
        case .all:
            let count = searchableSessionCount
            return "Ask across \(count) session\(count == 1 ? "" : "s")"
        case .session:
            if let row = selectedRow, !row.isQAAble {
                return "Transcription required first"
            }
            return "Fast QA for this session only"
        case let .sessions(ids):
            let qaAble = selectedQAAbleCount
            let skipped = ids.count - qaAble
            if qaAble == 0 {
                return "No QA-able sessions in selection"
            }
            if skipped > 0 {
                return "Ask across \(qaAble) selected session\(qaAble == 1 ? "" : "s") (\(skipped) skipped)"
            }
            return "Ask across \(qaAble) selected session\(qaAble == 1 ? "" : "s")"
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
        modelPlan = KnowledgeQAModelPolicy.currentPlan(models: models)
        flushPendingQueryIfNeeded()
    }

    func syncModelPlan(_ plan: LocalModelInstallPlan) {
        modelPlan = plan
        flushPendingQueryIfNeeded()
    }

    func refreshAccessGate() {
        if AccountService.shared.canCreateNewContent {
            accessBlockedMessage = nil
        } else {
            accessBlockedMessage = "Trial or Lifetime access is required to use the local Knowledge Base."
        }
    }

    func selectAll() {
        applyScope(.all, selectedIDs: [], anchor: nil)
    }

    func selectSession(_ id: UUID) {
        handleSessionClick(id, forceReplace: true)
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
        answerTask?.cancel()
        prepareTask?.cancel()
        pendingQuery = nil
        Task { await loadConversation(for: scope) }
    }

    func loadConversation(for scope: KnowledgeQAScope) async {
        let currentGeneration = UUID()
        loadGeneration = currentGeneration
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
        } catch {
            guard loadGeneration == currentGeneration else { return }
            self.errorMessage = error.localizedDescription
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

    /// Send / Voice-final entry. Model readiness is gated here, not on page enter.
    func send() {
        send(query: draft)
    }

    func send(query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering, !isPreparingKnowledgeModels else { return }
        refreshAccessGate()
        guard accessBlockedMessage == nil else { return }
        guard canAskCurrentScope else {
            errorMessage = qaBlockedMessage
            return
        }
        do {
            try AccountService.shared.requireNewContentAccess()
        } catch {
            refreshAccessGate()
            return
        }

        pendingQuery = text
        errorMessage = nil
        refreshModelPlan()
        if needsModelDownload {
            showModelGate = true
            if needsModelLicenseAcceptance {
                models.presentManager()
            }
            return
        }
        flushPendingQueryIfNeeded()
    }

    func downloadAndAsk() {
        let text = (pendingQuery ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
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
        errorMessage = nil
        prepareTask?.cancel()
        prepareTask = Task { await ensureModelsThenAsk() }
    }

    func cancelModelPreparation() {
        prepareTask?.cancel()
        prepareTask = nil
        isPreparingModels = false
        // Keep pendingQuery; do not auto-ask after cancel.
    }

    func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        isAnswering = false
        statusText = nil
    }

    private func ensureModelsThenAsk() async {
        do {
            try await models.ensureKnowledgeQAModels(
                answerModelID: KnowledgeQAModelPolicy.localAnswerModelID,
                includeReranker: KnowledgeQAModelPolicy.includeReranker
            )
            isPreparingModels = false
            refreshModelPlan()
        } catch is CancellationError {
            isPreparingModels = false
        } catch {
            isPreparingModels = false
            errorMessage = error.localizedDescription
            showModelGate = true
        }
    }

    private func flushPendingQueryIfNeeded() {
        guard KnowledgeQAReadyGate.shouldFlushPending(
            pendingQuery: pendingQuery,
            missingCount: modelPlan.missingItems.count,
            isAnswering: isAnswering
        ) else { return }
        let text = pendingQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pinnedScope = selectedScope
        guard let pinnedConversationID = conversation?.id else { return }
        pendingQuery = nil
        showModelGate = false
        isPreparingModels = false
        draft = ""
        errorMessage = nil
        answerTask?.cancel()
        answerTask = Task { await ask(text, scope: pinnedScope, conversationID: pinnedConversationID) }
    }

    private func ask(_ text: String) async {
        guard let conversation else {
            await loadConversation(for: selectedScope)
            guard self.conversation != nil else { return }
            await ask(text)
            return
        }
        let pinnedScope = selectedScope
        await ask(text, scope: pinnedScope, conversationID: conversation.id)
    }

    private func ask(_ text: String, scope: KnowledgeQAScope, conversationID: UUID) async {
        isAnswering = true
        statusText = "Starting…"
        defer {
            isAnswering = false
            statusText = nil
        }

        let userMessage = KnowledgeMessage(
            conversationID: conversationID,
            role: .user,
            content: text
        )
        messages.append(userMessage)
        do { try await chatStore.append(userMessage) } catch {
            errorMessage = error.localizedDescription
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

        let history = messages.filter { $0.id != assistantID && $0.id != userMessage.id }
        let request = KnowledgeQARequest(
            queryText: text,
            conversationID: conversationID,
            scope: scope,
            originFilter: originFilter.origins,
            history: history
        )

        var citations: [KnowledgeSourceRef] = []
        let stream = qaService.answer(request)
        do {
            for await event in stream {
                try Task.checkCancellation()
                guard conversation?.id == conversationID else { break }
                switch event {
                case let .status(status):
                    statusText = status
                case let .delta(chunk):
                    assistant.content += chunk
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .citations(refs):
                    citations = refs
                    assistant.citations = refs
                    upsertAssistant(assistant, conversationID: conversationID)
                case let .finished(finalText):
                    assistant.content = finalText
                    assistant.citations = citations
                    assistant.isStreaming = false
                    upsertAssistant(assistant, conversationID: conversationID)
                    guard conversation?.id == conversationID else { break }
                    try await chatStore.append(
                        KnowledgeMessage(
                            id: assistantID,
                            conversationID: conversationID,
                            role: .assistant,
                            content: finalText,
                            citations: citations,
                            isStreaming: false
                        )
                    )
                case let .failed(message):
                    assistant.content = message
                    assistant.isStreaming = false
                    upsertAssistant(assistant, conversationID: conversationID)
                    errorMessage = message
                    guard conversation?.id == conversationID else { break }
                    try await chatStore.append(assistant)
                }
            }
        } catch is CancellationError {
            assistant.isStreaming = false
            if assistant.content.isEmpty {
                messages.removeAll { $0.id == assistantID }
                if conversation?.id == conversationID {
                    Task {
                        do {
                            try await chatStore.removeMessage(id: userMessage.id, conversationID: conversationID)
                        } catch {}
                    }
                }
            } else {
                upsertAssistant(assistant, conversationID: conversationID)
                if conversation?.id == conversationID {
                    Task {
                        do {
                            try await chatStore.append(
                                KnowledgeMessage(
                                    id: assistantID,
                                    conversationID: conversationID,
                                    role: .assistant,
                                    content: assistant.content,
                                    citations: assistant.citations,
                                    isStreaming: false
                                )
                            )
                        } catch {}
                    }
                }
            }
        } catch {
            assistant.content = error.localizedDescription
            assistant.isStreaming = false
            upsertAssistant(assistant, conversationID: conversationID)
            errorMessage = error.localizedDescription
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
}
