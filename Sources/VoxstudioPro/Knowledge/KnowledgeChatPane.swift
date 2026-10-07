import AppKit
import Foundation
import SwiftUI

struct KnowledgeChatPane: View {
    @Bindable var controller: KnowledgeBaseController
    @Bindable private var workbench = WorkbenchStore.shared
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var aiSettings = LLMSettingsStore.shared
    @Bindable private var catalog = ProviderModelCatalog.shared
    @State private var showAIInfo = false
    var availableWidth: CGFloat
    @State private var isClearHovered = false

    private var livePlan: LocalModelInstallPlan {
        models.knowledgeQAInstallPlan(
            answerModelID: KnowledgeQAModelPolicy.localAnswerModelID,
            includeReranker: KnowledgeQAModelPolicy.includeReranker
        )
    }

    private var chatBackground: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.Background.baseColor,
                AppTheme.Background.surfaceColor.opacity(0.72),
                AppTheme.Background.baseColor,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            messages
            if let accessBlockedMessage = controller.accessBlockedMessage {
                accessBanner(accessBlockedMessage)
            } else if let answerBlockedMessage = controller.answerBlockedMessage {
                answerAvailabilityBanner(answerBlockedMessage)
            } else if let qaBlockedMessage = controller.qaBlockedMessage {
                qaBlockedBanner(qaBlockedMessage)
            }
            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
            }
            modelGate
            composer
        }
        .background(chatBackground)
        .onAppear {
            controller.syncModelPlan(livePlan)
        }
        .task { if aiSettings.useBYOK { await catalog.refresh(settings: aiSettings) } }
        .onReceive(NotificationCenter.default.publisher(for: .aiConfigurationDidChange)) { _ in
            Task { if aiSettings.useBYOK { await catalog.refresh(settings: aiSettings) } }
        }
        .onChange(of: livePlan) { _, newPlan in
            controller.syncModelPlan(newPlan)
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.19, green: 0.70, blue: 0.93).opacity(0.22),
                                Color(red: 0.33, green: 0.36, blue: 0.94).opacity(0.16),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(Color(red: 0.13, green: 0.52, blue: 0.82))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.scopeTitle)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(controller.scopeSubtitle)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                controller.clearHistory()
            } label: {
                if controller.isClearingHistory {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    BrushCleaningGlyph()
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isClearHovered ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(isClearHovered ? AppTheme.Background.raisedColor : AppTheme.Background.baseColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isClearHovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
            }
            .onHover { isClearHovered = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isClearHovered)
            .disabled(controller.messages.isEmpty || controller.isAnswering || controller.isClearingHistory)
            .accessibilityLabel(L10n.string("Clear chat history"))
            .help(L10n.string("Clear chat history"))
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .frame(height: AppTheme.Workbench.toolbarHeight)
        .background(AppTheme.Background.surfaceColor)
    }

    private var messages: some View {
        ChatScrollView(
            conversationID: controller.conversation?.id,
            updateToken: controller.messages.last,
            submittedMessageID: controller.messages.last(where: { $0.role == .user })?.id,
            horizontalInset: AppTheme.Spacing.mdLg
        ) { contentWidth in
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if controller.messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, AppTheme.Spacing.mdLg)
                }
                ForEach(controller.messages) { message in
                    KnowledgeMessageRow(
                        message: message,
                        status: message.isStreaming ? controller.statusText : nil,
                        cardWidth: min(AppTheme.Knowledge.messageMaxWidth,
                            max(1, contentWidth - AppTheme.Spacing.xxl - 8)),
                        onStop: controller.cancelAnswer,
                        onCitation: controller.openCitation,
                        onRecovery: controller.performRecoveryAction
                    )
                    .equatable()
                    .id(message.id)
                }
            }
            .padding(.vertical, AppTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch controller.selectedScope {
        case .all:
            allKnowledgeEmptyState
        case let .session(sessionID):
            focusedEmptyState(sessionID: sessionID)
        case .sessions:
            focusedEmptyState(sessionID: nil)
        }
    }

    private var allKnowledgeEmptyState: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            KnowledgeEmptyStateHeader(
                title: L10n.string("All knowledge"),
                subtitle: L10n.string("Open a recent session for focused questions, or view its generated summary."),
                systemImage: "square.stack.3d.up.fill"
            )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                Text(L10n.string("Recent sessions"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                if recentSessions.isEmpty {
                    Text(L10n.string("No recent knowledge sessions yet."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .padding(.vertical, AppTheme.Spacing.md)
                } else {
                    // ChatScrollView requires eager content; at most 8 rows.
                    VStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(recentSessions) { session in
                            KnowledgeRecentSessionRow(
                                session: session,
                                isSummaryLoading: controller.isLoadingSummaryForSessionID == session.id,
                                onOpen: { controller.selectSession(session.id) },
                                onSummary: { controller.showSummary(for: session.id) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: AppTheme.Knowledge.emptyStateMaxWidth, alignment: .leading)
    }

    private func focusedEmptyState(sessionID: UUID?) -> some View {
        VStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
            KnowledgeEmptyStateHeader(
                title: sessionID.map { controller.titleForSession($0) } ?? L10n.string("Ask your knowledge base"),
                subtitle: sessionID == nil
                    ? L10n.string("Choose a focused prompt for the selected sessions, or write your own question.")
                    : L10n.string("Choose a focused prompt or write your own question about this session."),
                systemImage: "text.bubble"
            )
            .frame(maxWidth: AppTheme.Knowledge.emptyStateMaxWidth, alignment: .leading)

            VStack(spacing: AppTheme.Spacing.sm) {
                ForEach(focusedPrompts(sessionID: sessionID)) { prompt in
                    Button {
                        if prompt.isSummary, let sessionID {
                            controller.showSummary(for: sessionID)
                        } else {
                            controller.send(query: L10n.string(prompt.titleKey))
                        }
                    } label: {
                        KnowledgeStarterPromptCard(
                            prompt: prompt,
                            isLoading: prompt.isSummary
                                && controller.isLoadingSummaryForSessionID == sessionID
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isAnswering)
                }
            }
            .frame(maxWidth: AppTheme.Knowledge.emptyStateMaxWidth)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var recentSessions: [WorkbenchSession] {
        let visibleIDs = Set(controller.rows.map(\.id))
        return workbench.sessions
            .filter { visibleIDs.contains($0.id) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(8)
            .map { $0 }
    }

    private func focusedPrompts(sessionID: UUID?) -> [KnowledgeStarterPrompt] {
        guard sessionID != nil else { return Self.starterPrompts }
        return [
            KnowledgeStarterPrompt(
                icon: "doc.text.magnifyingglass",
                titleKey: "View session summary",
                isSummary: true
            ),
        ] + Self.starterPrompts.dropFirst()
    }

    private func accessBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "lock.fill")
            Text(L10n.display(message))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(L10n.string("View plans")) {
                AppAccessWindow.shared.present()
            }
            .buttonStyle(.plain)
            .fontWeight(.semibold)
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Background.surfaceColor)
    }

    private func qaBlockedBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "text.badge.xmark")
            Text(L10n.display(message))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Background.surfaceColor)
    }

    private func answerAvailabilityBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "sparkles.rectangle.stack")
            Text(L10n.display(message))
                .lineLimit(3)
            Spacer(minLength: AppTheme.Spacing.zero)
            recoveryActions(controller.answerRecoveryActions)
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Background.surfaceColor)
    }

    private func recoveryActions(_ actions: [KnowledgeRecoveryAction]) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ForEach(actions, id: \.rawValue) { action in
                Button(L10n.string(key: recoveryLabel(action))) {
                    controller.performRecoveryAction(action)
                }
                .buttonStyle(.borderless)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            }
        }
    }

    private func recoveryLabel(_ action: KnowledgeRecoveryAction) -> String {
        switch action {
        case .account: L10n.key("Manage credits")
        case .aiSettings: L10n.key("Configure BYOK")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(L10n.display(message))
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(.orange)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var modelGate: some View {
        if controller.showModelGate, controller.needsModelDownload {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                LocalModelRequirementCard(plan: controller.modelPlan)
                HStack(spacing: AppTheme.Spacing.md) {
                    Button {
                        controller.downloadAndAsk()
                    } label: {
                        Text(L10n.string(controller.downloadAskLabel))
                            .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isPreparingKnowledgeModels)
                    if controller.isPreparingKnowledgeModels {
                        Button(L10n.string("Cancel")) {
                            controller.cancelModelPreparation()
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.sm)
        } else if controller.needsModelDownload, !controller.showModelGate {
            // Silent precheck status; Send still gated at ask time.
            EmptyView()
        }
    }

    private var composer: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.md) {
                KnowledgeComposerTextEditor(
                    text: $controller.draft,
                    placeholder: L10n.string("Ask a question…"),
                    onSubmit: { controller.send(query: $0) }
                )
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .disabled(
                        controller.accessBlockedMessage != nil
                            || controller.answerBlockedMessage != nil
                            || !controller.canAskCurrentScope
                    )

                InlineVoiceInputControl(
                    text: $controller.draft,
                    multiline: true,
                    presentation: .embedded
                )
                .disabled(!canUseVoiceInput)

                Button {
                    controller.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: AppTheme.IconSize.lg))
                        .foregroundStyle(canSend ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(L10n.string("Send"))
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                if aiSettings.useBYOK {
                    Menu {
                        ForEach(aiSettings.providers.filter { $0.agentProtocol != nil }) { provider in
                            Section(provider.normalizedDisplayName) {
                                ForEach(aiSettings.chatModelOptions.filter { option in
                                    guard option.reference.hasPrefix(provider.normalizedPrefix + "/") else { return false }
                                    if provider.agentProtocol == .openAICompatible {
                                        return option.modelName.hasPrefix("openai/gpt-")
                                            || (option.modelName.hasPrefix("anthropic/claude-") && ["haiku", "sonnet", "opus"].contains(where: { option.modelName.contains($0) }))
                                    }
                                    return true
                                }) { option in
                                    Button {
                                        aiSettings.selectChatModel(option)
                                    } label: {
                                        if option.id == aiSettings.effectiveChatModelOption?.id { Label(option.modelName, systemImage: "checkmark") }
                                        else { Text(verbatim: option.modelName) }
                                    }.disabled(!option.isAvailable)
                                }
                                if let error = catalog.errors[provider.id] { Text(L10n.display(error)) }
                            }
                        }
                        Divider()
                        Button(L10n.string("Refresh models"), systemImage: "arrow.clockwise") {
                            Task { await catalog.refresh(settings: aiSettings, force: true) }
                        }.disabled(!catalog.loading.isEmpty)
                        Button(L10n.string("AI Service settings…")) { controller.performRecoveryAction(.aiSettings) }
                    } label: {
                        KnowledgeComposerControlLabel(title: aiSettings.effectiveChatModelOption.map { $0.providerName + " · " + $0.modelName } ?? L10n.string("Configure BYOK"), systemImage: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(controller.isAnswering)
                    if !aiSettings.chatReasoningEffortsForCurrentModel.isEmpty {
                        Menu {
                            ForEach(aiSettings.chatReasoningEffortsForCurrentModel) { effort in
                                Button(L10n.string(effort.labelKey)) { aiSettings.chatReasoningEffort = effort }
                            }
                        } label: {
                            KnowledgeComposerControlLabel(title: L10n.string(aiSettings.effectiveChatReasoningEffort.labelKey), systemImage: "brain")
                        }.menuStyle(.borderlessButton).fixedSize().disabled(controller.isAnswering)
                    }
                } else {
                    KnowledgeComposerControlLabel(title: L10n.string("AI assistant"), systemImage: "sparkles")
                    Button { showAIInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain)
                        .help(L10n.string("About AI assistant"))
                        .popover(isPresented: $showAIInfo) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.string("About AI assistant")).font(.headline)
                                Text(L10n.string("Cloud automatically chooses an available AI model. Sign in to ask questions; usage follows your plan and consumes cloud credits. Relevant knowledge excerpts and your question are sent to the cloud service to generate an answer. Enable BYOK to choose a model and use your own provider key; requests then go to that provider and are billed by it."))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button(L10n.string("Account")) { showAIInfo = false; controller.performRecoveryAction(.account) }
                                    Button(L10n.string("AI Service")) { showAIInfo = false; controller.performRecoveryAction(.aiSettings) }
                                }
                            }.padding().frame(width: 360)
                        }
                }
                Spacer(minLength: AppTheme.Spacing.sm)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .fill(AppTheme.Background.baseColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: AppTheme.Workbench.composerMaxWidth)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var canSend: Bool {
        !controller.isPreparingKnowledgeModels
            && controller.accessBlockedMessage == nil
            && controller.answerBlockedMessage == nil
            && controller.canAskCurrentScope
            && !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canUseVoiceInput: Bool {
        controller.accessBlockedMessage == nil
            && controller.answerBlockedMessage == nil
            && controller.canAskCurrentScope
    }

}


private struct KnowledgeMessageRow: View, Equatable {
    let message: KnowledgeMessage
    let status: String?
    let cardWidth: CGFloat
    let onStop: () -> Void
    let onCitation: (KnowledgeSourceRef) -> Void
    let onRecovery: (KnowledgeRecoveryAction) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.status == rhs.status && lhs.cardWidth == rhs.cardWidth
    }

    var body: some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: AppTheme.Spacing.xxl) }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if isUser {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "person.fill")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        Text(L10n.string("You"))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(0.7)
                    }
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

                    Text(message.content)
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .textSelection(.enabled)
                    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        KnowledgeMessageCopyButton(
                            value: message.content,
                            label: L10n.string("Copy question")
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                            .foregroundStyle(Color(red: 0.12, green: 0.52, blue: 0.82))
                            .frame(width: 22, height: 22)
                            .background {
                                Circle()
                                    .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
                            }
                        Text(L10n.string("Knowledge assistant"))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .textCase(.uppercase)
                            .tracking(0.7)
                    }

                    if message.isStreaming {
                        KnowledgeAnswerStatusControl(
                            status: status ?? L10n.string("Working…"),
                            onStop: onStop
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if message.content.isEmpty && message.isStreaming {
                        EmptyView()
                    } else {
                        KnowledgeAnswerText(
                            text: message.content,
                            citations: message.citations,
                            proseFont: .system(size: AppTheme.FontSize.smMd)
                        )
                    }
                    if !message.citations.isEmpty {
                        citationRow(message.citations)
                    }
                    if !message.recoveryActions.isEmpty {
                        recoveryActions(message.recoveryActions)
                    }
                    if !message.isStreaming,
                       !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        KnowledgeMessageCopyButton(
                            value: KnowledgeAnswerPresentation.displayText(
                                message.content,
                                citationCount: message.citations.count
                            ),
                            label: L10n.string("Copy answer")
                        )
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(
                        isUser
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                            : AppTheme.Background.raisedColor.opacity(0.94)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isUser
                            ? AppTheme.Accent.primary.opacity(0.16)
                            : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.hairline
                    )
            }
            .shadow(
                color: isUser ? .clear : Color.black.opacity(0.08),
                radius: isUser ? 0 : 12,
                y: isUser ? 0 : 4
            )
            .frame(width: cardWidth, alignment: .leading)
            if !isUser { Spacer(minLength: AppTheme.Spacing.xxl) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func citationRow(_ citations: [KnowledgeSourceRef]) -> some View {
        let sources = KnowledgeAnswerPresentation.sourceGroups(citations)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.link)

                Text(L10n.string("Sources"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)

                Text(verbatim: "\(sources.count)")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Accent.link)
                    .padding(.horizontal, AppTheme.Spacing.xs)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(
                        Capsule()
                            .fill(AppTheme.Accent.link.opacity(AppTheme.Opacity.faint))
                    )

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L10n.format("%@, %@", L10n.string("Sources"), sources.count)))
            .help(L10n.string("Select a source to open its matching transcript"))

            FlowCitationChips(sources: sources) { ref in
                onCitation(ref)
            }

            if sources.count > 8 {
                Text(L10n.format("+%@ %@", sources.count - 8, L10n.string("more sources")))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.leading, AppTheme.Spacing.smMd)
            }
        }
    }

    private func recoveryActions(_ actions: [KnowledgeRecoveryAction]) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ForEach(actions, id: \.rawValue) { action in
                Button(L10n.string(key: recoveryLabel(action))) {
                    onRecovery(action)
                }
                .buttonStyle(.borderless)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            }
        }
    }

    private func recoveryLabel(_ action: KnowledgeRecoveryAction) -> String {
        switch action {
        case .account: L10n.key("Manage credits")
        case .aiSettings: L10n.key("Configure BYOK")
        }
    }

}

private struct KnowledgeComposerControlLabel: View {
    let title: String
    let systemImage: String

    private var controlFont: Font {
        .system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium)
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(controlFont)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
            Text(verbatim: title)
                .font(controlFont)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KnowledgeMessageCopyButton: View {
    private static let feedbackDuration: Duration = .seconds(1.4)

    let value: String
    let label: String
    @State private var status: CopyStatus = .idle
    @State private var feedbackID: UUID?

    var body: some View {
        Button(action: copy) {
            Image(systemName: status.iconName)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(status.tint)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, AppTheme.Spacing.xxs)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous))
            .hoverHighlight(cornerRadius: AppTheme.Radius.xs, isActive: status != .idle)
        }
        .buttonStyle(.plain)
        .help(status.helpText(label: label))
        .accessibilityLabel(Text(status.accessibilityLabel(label: label)))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            status = .failed
            return
        }

        let copyID = UUID()
        feedbackID = copyID
        status = .copied
        Task { @MainActor in
            try? await Task.sleep(for: Self.feedbackDuration)
            guard feedbackID == copyID else { return }
            status = .idle
        }
    }

    @MainActor
    private enum CopyStatus: Equatable {
        case idle
        case copied
        case failed

        var iconName: String {
            switch self {
            case .idle: "doc.on.doc"
            case .copied: "checkmark"
            case .failed: "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .idle: AppTheme.Text.tertiaryColor
            case .copied: AppTheme.Accent.primary
            case .failed: AppTheme.Status.errorColor
            }
        }

        func title(label: String) -> String {
            switch self {
            case .idle: label
            case .copied: L10n.string("Copied")
            case .failed: L10n.string("Copy failed")
            }
        }

        func helpText(label: String) -> String {
            title(label: label)
        }

        func accessibilityLabel(label: String) -> String {
            title(label: label)
        }
    }
}

/// The provided Lucide BrushCleaning glyph rendered directly in SwiftUI.
/// Using a custom path keeps this icon available even when the host macOS
/// version does not provide a matching SF Symbol.
private struct BrushCleaningGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 24
            Canvas { context, _ in
                let stroke = StrokeStyle(
                    lineWidth: 2 * scale,
                    lineCap: .round,
                    lineJoin: .round
                )

                var handle = Path()
                handle.addRoundedRect(
                    in: CGRect(x: 9 * scale, y: 2 * scale, width: 6 * scale, height: 12 * scale),
                    cornerSize: CGSize(width: 2 * scale, height: 2 * scale)
                )
                context.stroke(handle, with: .foreground, style: stroke)

                var body = Path()
                body.move(to: CGPoint(x: 5 * scale, y: 14 * scale))
                body.addLine(to: CGPoint(x: 19 * scale, y: 14 * scale))
                body.addLine(to: CGPoint(x: 20.973 * scale, y: 20.767 * scale))
                body.addQuadCurve(
                    to: CGPoint(x: 20 * scale, y: 22 * scale),
                    control: CGPoint(x: 21.3 * scale, y: 22 * scale)
                )
                body.addLine(to: CGPoint(x: 4 * scale, y: 22 * scale))
                body.addQuadCurve(
                    to: CGPoint(x: 3.027 * scale, y: 20.767 * scale),
                    control: CGPoint(x: 2.7 * scale, y: 22 * scale)
                )
                body.closeSubpath()
                context.stroke(body, with: .foreground, style: stroke)

                var leftDetail = Path()
                leftDetail.move(to: CGPoint(x: 8 * scale, y: 22 * scale))
                leftDetail.addLine(to: CGPoint(x: 9 * scale, y: 18 * scale))
                context.stroke(leftDetail, with: .foreground, style: stroke)

                var rightDetail = Path()
                rightDetail.move(to: CGPoint(x: 16 * scale, y: 22 * scale))
                rightDetail.addLine(to: CGPoint(x: 15 * scale, y: 18 * scale))
                context.stroke(rightDetail, with: .foreground, style: stroke)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// The status changes inside a stable box, without a timeline driving row layout.
private struct KnowledgeAnswerStatusControl: View {
    let status: String
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
            Text(L10n.display(status))
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Stop"))
            .accessibilityLabel(L10n.string("Stop"))
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: max(32, AppTheme.FontSize.xs + AppTheme.Spacing.sm * 2))
        .frame(maxWidth: 238)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("Answering: %@", L10n.display(status))))
    }
}

/// Full-width evidence rows. An adaptive grid gives a lone citation a narrow
/// column, which causes long source titles to truncate even when the answer
/// card has plenty of room. Each source now gets the complete answer width and
/// can wrap naturally when the title is genuinely longer than that width.
private struct FlowCitationChips: View {
    let sources: [KnowledgeCitationSource]
    let onTap: (KnowledgeSourceRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(sources.prefix(8)) { source in
                let ref = source.primaryReference
                HStack(spacing: AppTheme.Spacing.xs) {
                    Button {
                        onTap(ref)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: ref.sessionUUID == nil ? "doc.text" : "link")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                            Text(ref.chipLabel)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(ref.sessionUUID == nil)
                    .help(ref.sessionUUID == nil ? ref.chipLabel : L10n.string("Open transcript"))
                    .accessibilityLabel(Text(ref.sessionUUID == nil ? ref.chipLabel : L10n.format("Open transcript: %@", ref.chipLabel)))
                    if source.navigationReferences.count > 1 {
                        Menu {
                            ForEach(source.navigationReferences) { anchor in
                                Button(anchor.chipLabel) { onTap(anchor) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L10n.string("Select a source to open its matching transcript"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                )
                .accessibilityHint(ref.sessionUUID == nil ? ref.chipLabel : L10n.string("Select a source to open its matching transcript"))
            }
        }
    }
}

/// Source rows group evidence without changing the native citation-number map.
/// Timed evidence remains individually navigable within its source row.
struct KnowledgeCitationSource: Identifiable {
    let id: String
    var citations: [KnowledgeSourceRef]

    var navigationReferences: [KnowledgeSourceRef] {
        var seen = Set<String>()
        let timed = citations.filter { $0.startTime != nil && seen.insert($0.id).inserted }
        return timed.isEmpty ? Array(citations.suffix(1)) : timed
    }

    var primaryReference: KnowledgeSourceRef { navigationReferences[0] }
}

/// Keeps machine-generated citation tokens out of the reading flow. The source
/// list below the answer is the readable, clickable evidence affordance.
/// Unbracketed numeric facts remain intact.
enum KnowledgeAnswerPresentation {
    static func sourceGroups(_ citations: [KnowledgeSourceRef]) -> [KnowledgeCitationSource] {
        var sources: [KnowledgeCitationSource] = []
        var indices: [String: Int] = [:]
        for ref in citations {
            if let index = indices[ref.sourceID] {
                sources[index].citations.append(ref)
            } else {
                indices[ref.sourceID] = sources.count
                sources.append(.init(id: ref.sourceID, citations: [ref]))
            }
        }
        return sources
    }

    static func displayText(_ text: String, citationCount: Int) -> String {
        let hasCitationEvidence = citationCount > 0
            || !KnowledgeCitationMarkers.numbers(in: text).isEmpty
        guard hasCitationEvidence else { return text }

        let value = KnowledgeCitationMarkers.removing(from: text)

        // Bare numbers are indistinguishable from actual facts such as
        // “共有 4。” or “预算是 45。”; only bracketed markers are removable.
        return replacing(
            value,
            pattern: #"[ \t]+([。！？.!?；;，,、])"#,
            template: "$1"
        )
    }

    private static func replacing(
        _ text: String,
        pattern: String,
        template: String = ""
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

}

private struct KnowledgeAnswerText: View {
    let text: String
    let citations: [KnowledgeSourceRef]
    var proseFont: Font = .body

    var body: some View {
        MarkdownText(
            text: KnowledgeAnswerPresentation.displayText(
                text,
                citationCount: citations.count
            ),
            proseFont: proseFont
        )
    }
}

private struct KnowledgeStarterPrompt: Identifiable {
    let icon: String
    let titleKey: String
    var isSummary = false

    var id: String { titleKey }
}

private struct KnowledgeEmptyStateHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                .padding(AppTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
                )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct KnowledgeStarterPromptCard: View {
    let prompt: KnowledgeStarterPrompt
    var isLoading = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(
                        isHovered
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                            : AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                    )
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.Accent.primary)
                } else {
                    Image(systemName: prompt.icon)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)

            Text(L10n.string(prompt.titleKey))
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.Knowledge.starterPromptMinHeight, alignment: .center)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(
                    isHovered
                        ? AppTheme.Background.raisedColor
                        : AppTheme.Background.surfaceColor.opacity(0.72)
                )
        )
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(AppTheme.Accent.primary)
                .frame(width: isHovered ? AppTheme.BorderWidth.thick : AppTheme.BorderWidth.thin)
                .padding(.vertical, AppTheme.Spacing.sm)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    isHovered ? AppTheme.Accent.primary.opacity(0.42) : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        }
        .scaleEffect(isHovered ? 1.008 : 1)
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isHovered)
    }
}

private struct KnowledgeRecentSessionRow: View {
    let session: WorkbenchSession
    let isSummaryLoading: Bool
    let onOpen: () -> Void
    let onSummary: () -> Void

    @State private var isHovered = false

    private var title: String {
        session.title.isEmpty ? L10n.string("Untitled session") : session.title
    }

    private var summaryIcon: String {
        session.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "doc.text"
            : "sparkles"
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    session.sessionType.navGlyph.view(size: AppTheme.IconSize.lgXl)
                        .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                        .foregroundStyle(isHovered ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                                .fill(AppTheme.Accent.primary.opacity(isHovered ? 0.12 : 0.06))
                        )

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(title)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(L10n.string(key: session.sessionType.label))
                            metaDot
                            Text(session.storage == .cloud ? L10n.string("Cloud") : L10n.string("Local"))
                            if let duration = session.duration {
                                metaDot
                                Text(formatDuration(duration))
                            }
                        }
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)

                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(L10n.format("Created %@", session.createdAt.formatted(date: .abbreviated, time: .shortened)))
                            metaDot
                            Text(L10n.format("Updated %@", session.modifiedAt.formatted(date: .abbreviated, time: .shortened)))
                        }
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onSummary) {
                Group {
                    if isSummaryLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: summaryIcon)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    }
                }
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .foregroundStyle(isHovered ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(isHovered ? AppTheme.Accent.primary.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSummaryLoading)
            .help(L10n.string("View or generate summary"))
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(isHovered ? AppTheme.Background.raisedColor : AppTheme.Background.surfaceColor.opacity(0.70))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(
                    isHovered ? AppTheme.Accent.primary.opacity(0.36) : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        }
        .scaleEffect(isHovered ? 1.006 : 1)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isHovered)
    }

    private var metaDot: some View {
        Text("·")
            .foregroundStyle(AppTheme.Text.mutedColor)
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private extension KnowledgeChatPane {
    static let starterPrompts = [
        KnowledgeStarterPrompt(icon: "text.badge.checkmark", titleKey: "Summarize recent sessions"),
        KnowledgeStarterPrompt(icon: "list.bullet.rectangle", titleKey: "Find key decisions"),
        KnowledgeStarterPrompt(icon: "checklist", titleKey: "List action items"),
        KnowledgeStarterPrompt(icon: "envelope", titleKey: "Draft follow-up questions"),
    ]
}
