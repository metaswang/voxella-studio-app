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
    @FocusState private var inputFocused: Bool
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if controller.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, AppTheme.Spacing.mdLg)
                    }
                    ForEach(controller.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.md)
            }
            .onChange(of: controller.messages.last?.content) { _, _ in
                guard let lastID = controller.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
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
                    LazyVStack(spacing: AppTheme.Spacing.sm) {
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

    private func messageBubble(_ message: KnowledgeMessage) -> some View {
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
                            status: controller.statusText ?? L10n.string("Working…"),
                            onStop: controller.cancelAnswer
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
            .frame(maxWidth: AppTheme.Knowledge.messageMaxWidth, alignment: .leading)
            if !isUser { Spacer(minLength: AppTheme.Spacing.xxl) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .transition(.move(edge: isUser ? .trailing : .leading).combined(with: .opacity))
    }

    private func citationRow(_ citations: [KnowledgeSourceRef]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.link)

                Text(L10n.string("Sources"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)

                Text(verbatim: "\(citations.count)")
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
            .accessibilityLabel(Text(L10n.format("%@, %@", L10n.string("Sources"), citations.count)))
            .help(L10n.string("Select a source to open its matching transcript"))

            FlowCitationChips(citations: citations) { ref in
                controller.openCitation(ref)
            }

            if citations.count > 8 {
                Text(L10n.format("+%@ %@", citations.count - 8, L10n.string("more sources")))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.leading, AppTheme.Spacing.smMd)
            }
        }
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
                TextField(L10n.string("Ask a question…"), text: $controller.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .focused($inputFocused)
                    .onSubmit { controller.send() }
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
        .frame(maxWidth: AppTheme.Workbench.composerMaxWidth)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    private var canSend: Bool {
        !controller.isAnswering
            && !controller.isPreparingKnowledgeModels
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

/// A compact, text-shaped ellipsis with a soft traveling highlight.
private struct KnowledgeTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            let step = reduceMotion
                ? 1
                : Int(context.date.timeIntervalSinceReferenceDate / 0.42) % 4
            HStack(spacing: compact ? 2 : 3) {
                ForEach(0..<3, id: \.self) { index in
                    Text(".")
                        .font(.system(size: compact ? AppTheme.FontSize.xs : AppTheme.FontSize.smMd, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.66, blue: 0.92),
                                    Color(red: 0.32, green: 0.36, blue: 0.92),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(reduceMotion ? 0.72 : (index == step % 3 ? 1 : 0.25))
                        .scaleEffect(reduceMotion ? 1 : (index == step % 3 ? 1.18 : 0.86))
                        .offset(y: reduceMotion ? 0 : (index == step % 3 ? -1.5 : 1))
                        .animation(.easeInOut(duration: 0.22), value: step)
                }
            }
            .frame(minWidth: compact ? 21 : 25, alignment: .leading)
        }
        .frame(height: compact ? 15 : 20)
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

/// Header-level answer status control, inspired by the web knowledge-chat
/// progress rail but sized for the Mac toolbar.
private struct KnowledgeAnswerStatusControl: View {
    let status: String
    let onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                KnowledgeActivityBadge(reduceMotion: reduceMotion)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.string("Answering"))
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(Color(red: 0.12, green: 0.48, blue: 0.72))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(L10n.display(status))
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 132, alignment: .leading)
                KnowledgeTypingIndicator(compact: true)
            }
            .padding(.leading, AppTheme.Spacing.sm)
            .padding(.trailing, AppTheme.Spacing.xs)

            Rectangle()
                .fill(AppTheme.Border.subtleColor.opacity(0.8))
                .frame(width: AppTheme.BorderWidth.hairline, height: 22)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Stop"))
            .accessibilityLabel(L10n.string("Stop"))
        }
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.78, blue: 0.92).opacity(0.10),
                                    Color(red: 0.30, green: 0.36, blue: 0.94).opacity(0.08),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
        }
        .overlay(alignment: .bottomLeading) {
            KnowledgeIndeterminateRail(reduceMotion: reduceMotion)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.bottom, 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(Color(red: 0.33, green: 0.67, blue: 0.92).opacity(0.32), lineWidth: AppTheme.BorderWidth.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .shadow(color: Color(red: 0.18, green: 0.49, blue: 0.86).opacity(0.16), radius: 8, y: 3)
        .frame(maxWidth: 238)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.format("Answering: %@", L10n.display(status))))
    }
}

private struct KnowledgeActivityBadge: View {
    let reduceMotion: Bool

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            let pulse = reduceMotion
                ? 0.5
                : 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4.2)
            ZStack {
                Circle()
                    .fill(Color(red: 0.15, green: 0.66, blue: 0.92).opacity(0.12 + pulse * 0.12))
                    .scaleEffect(1.0 + pulse * 0.18)
                Circle()
                    .stroke(Color(red: 0.16, green: 0.62, blue: 0.9).opacity(0.4), lineWidth: 1)
                Image(systemName: "sparkles")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.5, blue: 0.78))
                    .scaleEffect(0.92 + pulse * 0.08)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct KnowledgeIndeterminateRail: View {
    let reduceMotion: Bool

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = reduceMotion
                    ? 0.28
                    : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(red: 0.15, green: 0.55, blue: 0.86).opacity(0.14))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.78, blue: 0.92),
                                    Color(red: 0.25, green: 0.38, blue: 0.94),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(24, width * 0.3))
                        .offset(x: (width + width * 0.3) * progress - width * 0.3)
                }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// Full-width evidence rows. An adaptive grid gives a lone citation a narrow
/// column, which causes long source titles to truncate even when the answer
/// card has plenty of room. Each source now gets the complete answer width and
/// can wrap naturally when the title is genuinely longer than that width.
private struct FlowCitationChips: View {
    let citations: [KnowledgeSourceRef]
    let onTap: (KnowledgeSourceRef) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(minimum: 0), spacing: AppTheme.Spacing.xs)],
            alignment: .leading,
            spacing: AppTheme.Spacing.xs
        ) {
            ForEach(citations.prefix(8)) { ref in
                Button {
                    onTap(ref)
                } label: {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "link")
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
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(L10n.string("Open transcript"))
                .accessibilityLabel(Text(L10n.format("Open transcript: %@", ref.chipLabel)))
                .accessibilityHint(L10n.string("Select a source to open its matching transcript"))
            }
        }
    }
}

/// Keeps machine-generated citation tokens out of the reading flow. The source
/// list below the answer is the readable, clickable evidence affordance, so a
/// user never has to decode a bare `45` or `[1, 4]` in otherwise natural prose.
enum KnowledgeAnswerPresentation {
    private static let numericCitationPattern = #"(?:\[\s*\d{1,3}(?:\s*[,，]\s*\d{1,3})*\s*\]|【\s*\d{1,3}(?:\s*[,，]\s*\d{1,3})*\s*】)"#
    private static let bareCitationPattern = #"[ \t]+\d{1,3}(?=[ \t]*(?:[。！？.!?；;，,、]|$))"#

    static func displayText(_ text: String, citationCount: Int) -> String {
        let hasCitationEvidence = citationCount > 0
            || containsMatch(text, pattern: numericCitationPattern)
            || hasRepeatedBareCitationTokens(in: text)
        guard hasCitationEvidence else { return text }

        var value = replacing(
            text,
            pattern: numericCitationPattern
        )

        // Some model/provider combinations emit citation indexes as a bare
        // token at the end of a sentence (`…内容 45。`). Only match a token
        // separated by horizontal whitespace and followed by punctuation or
        // the end of the answer, so ordinary values such as `20次` survive.
        value = replacing(
            value,
            pattern: bareCitationPattern
        )
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

    private static func containsMatch(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func hasRepeatedBareCitationTokens(in text: String) -> Bool {
        let bulletLines = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("• ")
        }
        return bulletLines.filter {
            containsMatch($0, pattern: bareCitationPattern)
        }.count >= 3
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
