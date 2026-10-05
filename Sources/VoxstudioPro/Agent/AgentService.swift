import Foundation
import Observation

@Observable
@MainActor
final class AgentService {
    typealias ToolOperation = @MainActor (String, [String: Any], String) async -> ToolResult

    private let userDefaults: UserDefaults
    private var reasoningEfforts: [AgentModel: AgentReasoningEffort]
    private var lastBYOKRunModelReference: String?
    private let transportOverride: AITransport?
    private var transport: AITransport { transportOverride ?? AITransportPolicy.current }
    @ObservationIgnored private let clientFactory: (@MainActor (AgentRunSettings) async -> (any AgentClient)?)?
    @ObservationIgnored private let toolOperation: ToolOperation?
    @ObservationIgnored private let checkpointInterval: Duration

    init(
        userDefaults: UserDefaults = .standard,
        transportOverride: AITransport? = nil,
        checkpointInterval: Duration = .seconds(2),
        clientFactory: (@MainActor (AgentRunSettings) async -> (any AgentClient)?)? = nil,
        toolOperation: ToolOperation? = nil
    ) {
        self.transportOverride = transportOverride
        self.clientFactory = clientFactory
        self.toolOperation = toolOperation
        self.checkpointInterval = max(.milliseconds(1), checkpointInterval)
        self.userDefaults = userDefaults
        self.model = userDefaults.string(forKey: "agentModel")
            .flatMap(AgentModel.persisted)
            ?? .defaultModel
        self.reasoningEfforts = Dictionary(uniqueKeysWithValues: AgentModel.allCases.map {
            ($0, AgentReasoningPreferences.effort(for: $0, defaults: userDefaults))
        })
    }

    var route: AgentRoute {
        switch transport {
        case .hosted:
            .hosted
        case .byok:
            LLMSettingsStore.shared.hasUsableAgentModel ? .direct : .unavailable
        case .unavailable:
            .unavailable
        }
    }

    var canStream: Bool {
        route != .unavailable
    }

    var availableModels: [AgentModel] {
        switch transport {
        case .byok:
            AgentModel.allCases
        case .hosted, .unavailable:
            AgentModel.allCases
        }
    }

    func canSelectModel(
        _ candidate: AgentModel,
        transport: AITransport = AITransportPolicy.current
    ) -> Bool {
        switch transport {
        case .hosted:
            true
        case .byok:
            true
        case .unavailable:
            false
        }
    }

    var activeBYOKProvider: LLMProviderProfile? {
        guard route == .direct else { return nil }
        if let reference = activeBYOKModelReference,
           let parsed = try? LLMSettingsStore.parseModelReference(reference) {
            return LLMSettingsStore.shared.providers.first { $0.normalizedPrefix == parsed.prefix }
        }
        return LLMSettingsStore.shared.route(for: .chat).modelChain.lazy.compactMap { reference in
            guard let parsed = try? LLMSettingsStore.parseModelReference(reference),
                  let profile = LLMSettingsStore.shared.providers.first(where: {
                      $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
                  }),
                  profile.agentProtocol != nil,
                  LLMSettingsStore.shared.hasAPIKey(for: profile.id)
            else { return nil }
            return profile
        }.first
    }

    var activeBYOKModelReference: String? {
        guard route == .direct else { return nil }
        if isStreaming, let lastBYOKRunModelReference { return lastBYOKRunModelReference }
        return LLMSettingsStore.shared.route(for: .chat).modelChain.first { reference in
            guard let parsed = try? LLMSettingsStore.parseModelReference(reference),
                  let profile = LLMSettingsStore.shared.providers.first(where: {
                      $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
                  }),
                  profile.agentProtocol != nil
            else { return false }
            return LLMSettingsStore.shared.hasAPIKey(for: profile.id)
        }
    }

    var reasoningEffort: AgentReasoningEffort {
        get {
            if transport == .byok {
                return AgentReasoningEffort(rawValue: LLMSettingsStore.shared.effectiveChatReasoningEffort.rawValue) ?? .medium
            }
            return reasoningEfforts[model, default: .medium]
        }
        set {
            guard reasoningEffortsForCurrentTransport.contains(newValue) else { return }
            if transport == .byok {
                LLMSettingsStore.shared.chatReasoningEffort = LLMReasoningEffort(rawValue: newValue.rawValue) ?? .medium
                return
            }
            reasoningEfforts[model] = newValue
            AgentReasoningPreferences.set(newValue, for: model, defaults: userDefaults)
        }
    }

    var reasoningEffortsForCurrentTransport: [AgentReasoningEffort] {
        if transport == .byok {
            return LLMSettingsStore.shared.chatReasoningEffortsForCurrentModel.compactMap { AgentReasoningEffort(rawValue: $0.rawValue) }
        }
        return route == .hosted ? AgentReasoningEffort.allCases : model.supportedReasoningEfforts
    }

    func snapshotRunSettings() -> AgentRunSettings {
        AgentRunSettings(model: model, reasoningEffort: reasoningEffort)
    }

    private func selectClient(for settings: AgentRunSettings, run: RunIdentity) async -> (any AgentClient)? {
        if let clientFactory { return await clientFactory(settings) }
        switch transport {
        case .hosted:
            return HostedAgentClient(settings: settings)
        case .byok:
            do {
                lastBYOKRunModelReference = nil
                var client = ProviderAgentClient(route: try await LLMSettingsStore.shared.agentRuntimeRoute())
                guard isCurrentRun(run) else { return nil }
                client.onModelSelected = { [weak self] model in
                    await MainActor.run {
                        guard let self, self.isCurrentRun(run) else { return }
                        self.lastBYOKRunModelReference = model
                    }
                }
                return client
            } catch {
                return nil
            }
        case .unavailable:
            return nil
        }
    }

    var model: AgentModel {
        didSet {
            userDefaults.set(model.rawValue, forKey: "agentModel")
            if case .unavailable = route {
                streamError = .unavailable(model)
            } else if case .some(.unavailable) = streamError {
                streamError = nil
            }
        }
    }

    var sessions: [ChatSession] = []
    var currentSessionId: UUID?
    var messages: [AgentMessage] = []
    private(set) var toolResults: [String: ToolResult] = [:]
    var isStreaming: Bool = false
    var streamError: AgentServiceError?
    var onSessionsChanged: (@MainActor () -> Void)?

    var draft: String = ""
    var mentions: [AgentMention] = []
    private static let clipMentionLabelMaxLength = 24

    func attachMention(for asset: MediaAsset) {
        editor?.agentPanelVisible = true
        pruneDetachedMentions()
        guard !mentions.contains(where: { $0.mediaRef == asset.id && !$0.referencesTimelineContext }) else { return }
        let displayName = Self.disambiguatedMentionName(for: asset, existing: mentions)
        appendMentionToken(displayName)
        mentions.append(AgentMention(displayName: displayName, mediaRef: asset.id, type: asset.type))
    }

    func attachMentions(forClipIds clipIds: [String]) {
        guard let editor, !clipIds.isEmpty else { return }
        editor.agentPanelVisible = true
        pruneDetachedMentions()

        let existingClipIds = Set(mentions.compactMap(\.clipId))
        for ref in Self.clipMentionReferences(for: clipIds, editor: editor) where !existingClipIds.contains(ref.clip.id) {
            let displayName = Self.disambiguatedClipMentionName(
                for: ref.clip,
                label: ref.label,
                trackLabel: ref.trackLabel,
                fps: editor.timeline.fps,
                existing: mentions
            )
            appendMentionToken(displayName)
            mentions.append(AgentMention(
                displayName: displayName,
                mediaRef: ref.clip.mediaRef,
                type: ref.clip.mediaType,
                clipId: ref.clip.id
            ))
        }
    }

    func attachSelectedTimelineRangeMention() {
        guard let editor, let range = editor.validSelectedTimelineRange else { return }
        editor.agentPanelVisible = true
        pruneDetachedMentions()

        let timelineRange = AgentTimelineRangeMention(range: range, fps: editor.timeline.fps)
        guard !mentions.contains(where: { $0.timelineRange == timelineRange }) else { return }

        let displayName = Self.disambiguatedTimelineRangeMentionName(for: timelineRange, existing: mentions)
        appendMentionToken(displayName)
        mentions.append(AgentMention(displayName: displayName, timelineRange: timelineRange))
    }

    private func pruneDetachedMentions() {
        mentions.removeAll { !draft.contains("@\($0.displayName)") }
    }

    private func appendMentionToken(_ displayName: String) {
        let needsSpace = !draft.isEmpty && !draft.hasSuffix(" ") && !draft.hasSuffix("\n")
        draft += (needsSpace ? " " : "") + "@\(displayName) "
    }

    static func disambiguatedMentionName(for asset: MediaAsset, existing: [AgentMention]) -> String {
        let base = asset.mentionDisplayName
        if !existing.contains(where: { $0.displayName == base && $0.mediaRef != asset.id }) {
            return base
        }
        let short = String(asset.id.prefix(6))
        return "\(base)#\(short)"
    }

    static func disambiguatedClipMentionName(
        for clip: Clip,
        label: String,
        trackLabel: String,
        fps: Int,
        existing: [AgentMention]
    ) -> String {
        let shortLabel = compactClipMentionLabel(label)
        let base = AgentMention.makeDisplayName(
            from: "\(shortLabel)-\(trackLabel)-\(formatTimecode(frame: clip.startFrame, fps: fps))"
        )
        let fallback = "Clip-\(String(clip.id.prefix(6)))"
        let candidate = base.isEmpty ? fallback : base
        if !existing.contains(where: { $0.displayName == candidate && $0.clipId != clip.id }) {
            return candidate
        }
        let short = String(clip.id.prefix(6))
        return "\(candidate)#\(short)"
    }

    private static func compactClipMentionLabel(_ label: String) -> String {
        let display = AgentMention.makeDisplayName(from: label)
        guard display.count > clipMentionLabelMaxLength else { return display }
        let end = display.index(display.startIndex, offsetBy: clipMentionLabelMaxLength)
        return String(display[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func disambiguatedTimelineRangeMentionName(
        for range: AgentTimelineRangeMention,
        existing: [AgentMention]
    ) -> String {
        let base = AgentMention.makeDisplayName(from: "Range-\(range.startTimecode)-\(range.endTimecode)")
        let fallback = "Range-\(range.startFrame)-\(range.endFrame)"
        let candidate = base.isEmpty ? fallback : base
        if !existing.contains(where: { $0.displayName == candidate && $0.timelineRange != range }) {
            return candidate
        }
        return "\(candidate)#\(range.startFrame)-\(range.endFrame)"
    }

    private struct ClipMentionReference {
        let clip: Clip
        let label: String
        let trackLabel: String
    }

    private static func clipMentionReferences(for clipIds: [String], editor: EditorViewModel) -> [ClipMentionReference] {
        let requested = Set(clipIds)
        var refs: [ClipMentionReference] = []
        for (trackIndex, track) in editor.timeline.tracks.enumerated() {
            let trackLabel = editor.timelineTrackDisplayLabel(at: trackIndex)
            for clip in track.clips where requested.contains(clip.id) {
                refs.append(ClipMentionReference(
                    clip: clip,
                    label: editor.clipDisplayLabel(for: clip),
                    trackLabel: trackLabel
                ))
            }
        }
        return refs
    }

    weak var editor: EditorViewModel? {
        didSet { toolExecutor = editor.map { ToolExecutor(editor: $0) } }
    }
    private var toolExecutor: ToolExecutor?
    private struct RunIdentity: Equatable, Sendable {
        let id = UUID()
        let conversationID: UUID
    }
    @ObservationIgnored private var activeRun: RunIdentity?
    @ObservationIgnored private var activeAssistantID: UUID?
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?

    func loadSessions(from projectURL: URL?) {
        if activeRun != nil {
            stopCurrentRun()
            checkpointMessages()
        }
        sessions = ChatSessionStore.load(from: projectURL)
            .filter { !$0.messages.isEmpty }
            .map {
                var session = $0
                session.isOpen = false
                return session
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        messages = []
        toolResults = [:]
        draft = ""
        mentions.removeAll()
        streamError = nil
        toolExecutor?.resetFeedbackState()
    }

    func newChat() {
        stopCurrentRun()
        syncMessagesIntoCurrentSession()
        if let id = currentSessionId,
           let idx = sessions.firstIndex(where: { $0.id == id }),
           sessions[idx].messages.isEmpty {
            sessions.remove(at: idx)
        }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        messages = []
        toolResults = [:]
        streamError = nil
        toolExecutor?.resetFeedbackState()
        onSessionsChanged?()
    }

    var openSessions: [ChatSession] { sessions.filter { $0.isOpen } }

    func selectSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        stopCurrentRun()
        syncMessagesIntoCurrentSession()
        if !sessions[idx].isOpen {
            sessions[idx].isOpen = true
        }
        currentSessionId = id
        restoreMessages(from: sessions[idx])
        streamError = nil
        onSessionsChanged?()
    }

    func closeTab(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        if currentSessionId == id {
            stopCurrentRun()
            syncMessagesIntoCurrentSession()
        }
        sessions[idx].isOpen = false
        if currentSessionId == id {
            if let next = sessions.first(where: { $0.isOpen }) {
                currentSessionId = next.id
                restoreMessages(from: next)
                streamError = nil
            } else {
                newChat()
                return
            }
        }
        onSessionsChanged?()
    }

    func deleteSession(_ id: UUID) {
        if currentSessionId == id { stopCurrentRun() }
        sessions.removeAll { $0.id == id }
        if currentSessionId == id {
            currentSessionId = sessions.first(where: { $0.isOpen })?.id
            restoreMessages(from: currentSessionId.flatMap { id in sessions.first { $0.id == id } })
            streamError = nil
        }
        if openSessions.isEmpty { newChat(); return }
        onSessionsChanged?()
    }

    private func restoreMessages(from session: ChatSession?) {
        let restored = session?.messages ?? []
        messages = restored
        // No execution remains attached to a restored history. Only unresolved
        // calls need a cancellation result; completed calls remain unchanged.
        resolveOrphanToolUses()
        rebuildToolResultIndex()
        if messages != restored { syncMessagesIntoCurrentSession() }
    }

    func send(text: String, mentions: [AgentMention]) {
        guard canStream else {
            streamError = .unavailable(model)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let conversationID = currentSessionId else {
            streamError = .upstream("Chat session unavailable.")
            return
        }
        stopCurrentRun()
        let referencedMentions = AgentMentionContext.referencedMentions(mentions, in: trimmed)
        let contextHint = referencedMentions.isEmpty
            ? nil
            : AgentMentionContext.hint(referencedMentions, editor: editor)
        let runSettings = snapshotRunSettings()
        var sessionActivation = Analytics.SessionActivation(
            isActivated: messages.contains { $0.role == .user }
        )
        let analyticsPayload: [String: Any] = [
            "project_id": editor?.projectId ?? "unknown",
            "model": (transport == .byok ? lastBYOKRunModelReference : nil) ?? runSettings.model.rawValue,
        ]
        if sessionActivation.activate() {
            Analytics.capture(.agentSessionStarted, properties: analyticsPayload)
        }

        resolveOrphanToolUses()
        messages.append(AgentMessage(
            role: .user, blocks: [.text(trimmed)],
            mentions: referencedMentions, contextHint: contextHint
        ))
        streamError = nil
        checkpointMessages()
        kickOffStream(
            conversationID: conversationID,
            traceID: UUID(),
            settings: runSettings
        )
    }

    func postSystemNotice(_ text: String) {
        messages.append(AgentMessage(role: .system, blocks: [.text(text)]))
        checkpointMessages()
    }

    func cancel() {
        stopCurrentRun()
        checkpointMessages()
    }

    private func stopCurrentRun() {
        // Invalidate before cancellation: an old await/defer may resume after a
        // replacement run has already started on the same session.
        activeRun = nil
        currentTask?.cancel()
        currentTask = nil
        checkpointTask?.cancel()
        checkpointTask = nil
        isStreaming = false
        if let activeAssistantID { dropEmptyAssistantTurn(id: activeAssistantID) }
        activeAssistantID = nil
        resolveOrphanToolUses()
    }

    private func isCurrentRun(_ run: RunIdentity) -> Bool {
        activeRun == run && currentSessionId == run.conversationID
    }

    private func finishRun(_ run: RunIdentity) {
        guard isCurrentRun(run) else { return }
        isStreaming = false
        checkpointMessages()
        activeRun = nil
        activeAssistantID = nil
        currentTask = nil
    }

    private func checkpointMessages() {
        checkpointTask?.cancel()
        checkpointTask = nil
        syncMessagesIntoCurrentSession()
        onSessionsChanged?()
    }

    private func scheduleCheckpoint(for run: RunIdentity) {
        // Throttle rather than debounce so continuous output still gets saved.
        guard isCurrentRun(run), checkpointTask == nil else { return }
        let interval = checkpointInterval
        checkpointTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self, self.isCurrentRun(run), !Task.isCancelled else { return }
            self.checkpointMessages()
        }
    }

    private func kickOffStream(
        conversationID: UUID,
        traceID: UUID,
        settings: AgentRunSettings
    ) {
        let run = RunIdentity(conversationID: conversationID)
        activeRun = run
        isStreaming = true
        currentTask = Task { [weak self] in
            defer { self?.finishRun(run) }
            await self?.runLoop(
                run: run,
                traceID: traceID,
                settings: settings
            )
        }
    }

    private func runLoop(
        run: RunIdentity,
        traceID: UUID,
        settings: AgentRunSettings
    ) async {
        let chosenModel = settings.model
        let selectedClient = await selectClient(for: settings, run: run)
        guard isCurrentRun(run), !Task.isCancelled else { return }
        guard let client = selectedClient else {
            streamError = .unavailable(chosenModel)
            return
        }
        if Task.isCancelled { return }
        await SkillStore.shared.reloadInBackground()
        guard isCurrentRun(run), !Task.isCancelled else { return }
        let tools = ToolDefinitions.inAppAgent.map {
            AgentToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        loop: while isCurrentRun(run), !Task.isCancelled {
            resolveOrphanToolUses()
            let apiMsgs = await apiMessages(for: run)
            guard isCurrentRun(run), !Task.isCancelled else { return }
            guard let inputMessageID = messages.last(where: { $0.role == .user })?.id else {
                streamError = .upstream("The agent request has no user message.")
                break loop
            }
            let assistant = AgentMessage(role: .assistant, blocks: [])
            messages.append(assistant)
            let assistantID = assistant.id
            activeAssistantID = assistantID

            do {
                let stream = client.stream(
                    system: AgentInstructions.serverInstructions + AgentInstructions.skillsSection(SkillStore.shared.skillIndex),
                    tools: tools,
                    messages: apiMsgs,
                    context: AgentRequestContext(
                        conversationID: run.conversationID,
                        traceID: traceID,
                        spanID: UUID(),
                        inputMessageID: inputMessageID,
                        outputMessageID: assistantID,
                        projectID: editor?.projectId
                    )
                )

                var stopReason: AgentStopReason = .endTurn

                for try await event in stream {
                    try Task.checkCancellation()
                    guard isCurrentRun(run) else { return }
                    switch event {
                    case .thinkingDelta(let chunk):
                        updateThinking(textDelta: chunk, toAssistant: assistantID)
                    case .thinkingSignature(let signature):
                        updateThinking(signatureDelta: signature, toAssistant: assistantID)
                    case .redactedThinking(let data):
                        appendRedactedThinking(data, toAssistant: assistantID)
                    case .reasoningSummaryDelta(let chunk, let sourceModel):
                        appendReasoningDelta(chunk, model: sourceModel ?? chosenModel, toAssistant: assistantID)
                    case .reasoningComplete(let itemID, let summary, let encryptedContent, let sourceModel):
                        completeReasoning(
                            itemID: itemID,
                            summary: summary,
                            encryptedContent: encryptedContent,
                            model: sourceModel ?? chosenModel,
                            toAssistant: assistantID
                        )
                    case .textDelta(let chunk):
                        appendTextDelta(chunk, toAssistant: assistantID)
                    case .toolUseComplete(let id, let name, let inputJSON):
                        appendToolUse(id: id, name: name, inputJSON: inputJSON, toAssistant: assistantID)
                    case .messageStop(let reason):
                        stopReason = reason
                    case .tokenUsage: break
                    }
                    if case .tokenUsage = event { continue }
                    scheduleCheckpoint(for: run)
                }

                guard isCurrentRun(run), !Task.isCancelled else { return }
                dropEmptyAssistantTurn(id: assistantID)
                if stopReason == .refusal {
                    streamError = .refusal(chosenModel)
                    break loop
                }
                if stopReason == .toolUse {
                    await runPendingToolUses(assistantID: assistantID, run: run)
                    guard isCurrentRun(run), !Task.isCancelled else { return }
                    continue loop
                }
                if Task.isCancelled { break loop }
                break loop
            } catch is CancellationError {
                guard isCurrentRun(run) else { return }
                dropEmptyAssistantTurn(id: assistantID)
                break loop
            } catch let err as AgentServiceError {
                guard isCurrentRun(run) else { return }
                dropEmptyAssistantTurn(id: assistantID)
                streamError = err
                break loop
            } catch let err as AgentClientTransportError {
                guard isCurrentRun(run) else { return }
                switch err {
                case .insufficientCredits(let message):
                    // The hosted API settles after streaming. If settlement
                    // fails, do not retain a partial assistant turn.
                    dropAssistantTurn(id: assistantID)
                    streamError = .insufficientCredits(message)
                default:
                    dropEmptyAssistantTurn(id: assistantID)
                    streamError = .upstream(err.localizedDescription)
                }
                break loop
            } catch {
                guard isCurrentRun(run) else { return }
                dropEmptyAssistantTurn(id: assistantID)
                streamError = .upstream(error.localizedDescription)
                break loop
            }
        }
    }

    private func assistantMessageIndex(id: UUID) -> Int? {
        messages.firstIndex { $0.id == id && $0.role == .assistant }
    }

    func dropEmptyAssistantTurn(id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        messages[index].blocks.removeAll { !Self.isComplete($0) }
        guard messages[index].blocks.isEmpty else { return }
        messages.remove(at: index)
    }

    func dropAssistantTurn(id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        messages.remove(at: index)
    }

    private static func isComplete(_ block: AgentContentBlock) -> Bool {
        switch block {
        case .thinking(_, let signature):
            !signature.isEmpty
        case .redactedThinking(let data):
            !data.isEmpty
        case .openAIReasoning(_, let encryptedContent, _, _):
            !encryptedContent.isEmpty
        case .text(let text):
            !text.isEmpty
        case .toolUse, .toolResult:
            true
        }
    }

    private func updateThinking(
        textDelta: String = "",
        signatureDelta: String = "",
        toAssistant id: UUID
    ) {
        guard let index = assistantMessageIndex(id: id) else { return }
        if case .thinking(let text, let signature)? = messages[index].blocks.last {
            messages[index].blocks[messages[index].blocks.count - 1] = .thinking(
                text: text + textDelta,
                signature: signature + signatureDelta
            )
        } else {
            messages[index].blocks.append(.thinking(
                text: textDelta,
                signature: signatureDelta
            ))
        }
    }

    private func appendRedactedThinking(_ data: String, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        messages[index].blocks.append(.redactedThinking(data: data))
    }

    /// Removes and returns the current streaming reasoning summary for `model`.
    private func takeStreamingReasoningSummary(at index: Int, model: AgentModel) -> String {
        guard case .openAIReasoning(let summary, _, _, let existingModel)?
            = messages[index].blocks.last,
            existingModel == model
        else { return "" }
        messages[index].blocks.removeLast()
        return summary
    }

    private func appendReasoningDelta(_ chunk: String, model: AgentModel, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        let existing = takeStreamingReasoningSummary(at: index, model: model)
        messages[index].blocks.append(.openAIReasoning(
            summary: existing + chunk,
            encryptedContent: "",
            itemID: nil,
            model: model
        ))
    }

    private func completeReasoning(
        itemID: String?,
        summary: String,
        encryptedContent: String,
        model: AgentModel,
        toAssistant id: UUID
    ) {
        guard let index = assistantMessageIndex(id: id) else { return }
        let existing = takeStreamingReasoningSummary(at: index, model: model)
        messages[index].blocks.append(.openAIReasoning(
            summary: summary.isEmpty ? existing : summary,
            encryptedContent: encryptedContent,
            itemID: itemID,
            model: model
        ))
    }

    private func appendTextDelta(_ chunk: String, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        if case .text(let existing)? = messages[index].blocks.last {
            messages[index].blocks[messages[index].blocks.count - 1] = .text(existing + chunk)
        } else {
            messages[index].blocks.append(.text(chunk))
        }
    }

    private func appendToolUse(id toolUseID: String, name: String, inputJSON: String, toAssistant assistantID: UUID) {
        guard let index = assistantMessageIndex(id: assistantID) else { return }
        messages[index].blocks.append(.toolUse(id: toolUseID, name: name, inputJSON: inputJSON))
    }

    private func runPendingToolUses(assistantID: UUID, run: RunIdentity) async {
        guard isCurrentRun(run), !Task.isCancelled else { return }
        guard let assistantIndex = assistantMessageIndex(id: assistantID) else { return }
        let toolUses: [(id: String, name: String, input: String)] = messages[assistantIndex].blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
        let alreadyResolved = resolvedToolUseIds(afterAssistantAt: assistantIndex)
        for use in toolUses where !alreadyResolved.contains(use.id) {
            guard isCurrentRun(run), !Task.isCancelled else { return }
            let args = Self.parseJSONObject(use.input)
            let result: ToolResult
            if let toolOperation {
                result = await toolOperation(use.name, args, run.conversationID.uuidString)
            } else if let executor = toolExecutor {
                result = await executor.execute(
                    name: use.name,
                    args: args,
                    sessionID: run.conversationID.uuidString
                )
            } else {
                result = .error("Tool executor unavailable.")
            }
            guard isCurrentRun(run), !Task.isCancelled else { return }
            appendToolResults([
                .toolResult(toolUseId: use.id, content: result.content, isError: result.isError)
            ], afterAssistant: assistantID)
            // A later tool can suspend for minutes. Save each completed result
            // before moving on, preserving it if that later operation is stopped.
            checkpointMessages()
        }
    }

    private func appendToolResults(_ blocks: [AgentContentBlock], afterAssistant assistantID: UUID) {
        guard let assistantIndex = assistantMessageIndex(id: assistantID) else { return }
        let resolved = resolvedToolUseIds(afterAssistantAt: assistantIndex)
        let pending = blocks.filter {
            guard case .toolResult(let id, _, _) = $0 else { return false }
            return !resolved.contains(id)
        }
        guard !pending.isEmpty else { return }
        let next = nextNonSystemIndex(after: assistantIndex)
        if next < messages.count, messages[next].role == .user,
           messages[next].blocks.allSatisfy({ if case .toolResult = $0 { true } else { false } }) {
            messages[next].blocks.append(contentsOf: pending)
        } else {
            messages.insert(AgentMessage(role: .user, blocks: pending), at: next)
        }
        indexToolResults(in: pending)
    }

    func rebuildToolResultIndex() {
        toolResults = [:]
        for message in messages { indexToolResults(in: message.blocks) }
    }

    private func indexToolResults(in blocks: [AgentContentBlock]) {
        for block in blocks {
            if case let .toolResult(id, content, isError) = block {
                toolResults[id] = ToolResult(content: content, isError: isError)
            }
        }
    }

    private func nextNonSystemIndex(after index: Int) -> Int {
        var next = index + 1
        while next < messages.count, messages[next].role == .system { next += 1 }
        return next
    }

    private func resolvedToolUseIds(afterAssistantAt index: Int) -> Set<String> {
        let next = nextNonSystemIndex(after: index)
        guard next < messages.count, messages[next].role == .user else { return [] }
        return Set(messages[next].blocks.compactMap {
            if case let .toolResult(id, _, _) = $0 { return id }
            return nil
        })
    }

    private func resolveOrphanToolUses(reason: String = "Cancelled") {
        var i = 0
        while i < messages.count {
            defer { i += 1 }
            guard messages[i].role == .assistant else { continue }
            let toolUseIds: [String] = messages[i].blocks.compactMap {
                if case let .toolUse(id, _, _) = $0 { return id }
                return nil
            }
            guard !toolUseIds.isEmpty else { continue }

            let next = nextNonSystemIndex(after: i)
            let nextIsToolResult = next < messages.count
                && messages[next].role == .user
                && messages[next].blocks.contains(where: {
                    if case .toolResult = $0 { return true }
                    return false
                })
            let resolved: Set<String> = nextIsToolResult
                ? Set(messages[next].blocks.compactMap {
                    if case let .toolResult(id, _, _) = $0 { return id }
                    return nil
                })
                : []

            let orphans = toolUseIds.filter { !resolved.contains($0) }
            guard !orphans.isEmpty else { continue }

            let synthetic: [AgentContentBlock] = orphans.map {
                .toolResult(toolUseId: $0, content: [.text(reason)], isError: true)
            }
            indexToolResults(in: synthetic)
            if nextIsToolResult {
                messages[next].blocks.insert(contentsOf: synthetic, at: 0)
            } else {
                messages.insert(AgentMessage(role: .user, blocks: synthetic), at: next)
            }
        }
    }

    private static func parseJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func syncMessagesIntoCurrentSession() {
        guard let id = currentSessionId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].messages = messages
        sessions[idx].updatedAt = Date()
        if sessions[idx].title == "New chat",
           let first = messages.first(where: { $0.role == .user }) {
            sessions[idx].title = Self.title(from: first)
        }
    }

    private func apiMessages(for run: RunIdentity) async -> [AgentRequestMessage] {
        var result: [AgentRequestMessage] = []
        for msg in messages {
            guard isCurrentRun(run), !Task.isCancelled else { return [] }
            if msg.role == .system { continue }
            var content = msg.blocks.map(AgentRequestBlock.content)
            if msg.role == .user, !msg.mentions.isEmpty {
                let inlined = await inlineImageBlocks(for: msg.mentions)
                guard isCurrentRun(run), !Task.isCancelled else { return [] }
                var hint = msg.contextHint ?? AgentMentionContext.hint(msg.mentions, editor: editor)
                if let note = AgentMentionContext.inlineNote(for: inlined) { hint += " " + note }
                content.insert(contentsOf: inlined.blocks, at: 0)
                content.insert(.content(.text(hint)), at: 0)
            }
            guard !content.isEmpty else { continue }
            result.append(AgentRequestMessage(role: msg.role == .user ? .user : .assistant, content: content))
        }
        return result
    }

    private func inlineImageBlocks(for mentions: [AgentMention]) async -> AgentMentionContext.InlinedMentions {
        var out = AgentMentionContext.InlinedMentions()
        guard let editor else {
            for mention in mentions where mention.type == .image {
                if let mediaRef = mention.mediaRef { out.failures[mediaRef] = "editor unavailable" }
            }
            return out
        }
        // Resolve mention -> URL on the main actor, then encode off it.
        var pending: [(mediaRef: String, url: URL)] = []
        for mention in mentions where mention.type == .image {
            guard let mediaRef = mention.mediaRef else { continue }
            guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
                out.failures[mediaRef] = "asset not in media library"
                continue
            }
            pending.append((mediaRef, asset.url))
        }
        let jobs = pending
        let encoded = await Task.detached(priority: .userInitiated) {
            jobs.map { job in
                (job.mediaRef, ImageEncoder.encode(url: job.url).map { ($0.mime, $0.data.base64EncodedString()) })
            }
        }.value
        for (mediaRef, result) in encoded {
            guard let (mime, base64) = result else {
                out.failures[mediaRef] = "could not read or decode image file"
                continue
            }
            out.blocks.append(.image(base64: base64, mediaType: mime))
            out.inlinedIds.insert(mediaRef)
        }
        return out
    }

    private static func title(from message: AgentMessage) -> String {
        for block in message.blocks {
            if case let .text(s) = block {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
            }
        }
        return "New chat"
    }
}

struct AgentMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, system }
    let id: UUID
    let role: Role
    var blocks: [AgentContentBlock]
    var mentions: [AgentMention]
    var contextHint: String?

    init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], mentions: [AgentMention] = [], contextHint: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
        self.contextHint = contextHint
    }
}

enum AgentContentBlock: Codable, Sendable, Equatable {
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)
    case openAIReasoning(
        summary: String,
        encryptedContent: String,
        itemID: String?,
        model: AgentModel
    )
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: [ToolResult.Block], isError: Bool)

    private enum Kind: String, Codable {
        case thinking, redactedThinking, openAIReasoning, text, toolUse, toolResult
    }
    private enum CodingKeys: String, CodingKey {
        case kind, text, signature, data, id, name, input, toolUseId, content, isError
        case summary, encryptedContent, itemID, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .thinking:
            self = .thinking(
                text: try c.decode(String.self, forKey: .text),
                signature: try c.decode(String.self, forKey: .signature)
            )
        case .redactedThinking:
            self = .redactedThinking(data: try c.decode(String.self, forKey: .data))
        case .openAIReasoning:
            self = .openAIReasoning(
                summary: try c.decode(String.self, forKey: .summary),
                encryptedContent: try c.decode(String.self, forKey: .encryptedContent),
                itemID: try c.decodeIfPresent(String.self, forKey: .itemID),
                model: try c.decode(AgentModel.self, forKey: .model)
            )
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode([ToolResult.Block].self, forKey: .content),
                isError: try c.decode(Bool.self, forKey: .isError)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .thinking(let text, let signature):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(signature, forKey: .signature)
        case .redactedThinking(let data):
            try c.encode(Kind.redactedThinking, forKey: .kind)
            try c.encode(data, forKey: .data)
        case .openAIReasoning(let summary, let encryptedContent, let itemID, let model):
            try c.encode(Kind.openAIReasoning, forKey: .kind)
            try c.encode(summary, forKey: .summary)
            try c.encode(encryptedContent, forKey: .encryptedContent)
            try c.encodeIfPresent(itemID, forKey: .itemID)
            try c.encode(model, forKey: .model)
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let inputJSON):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }
}
