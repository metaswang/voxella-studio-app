import SwiftUI

struct KnowledgeChatPane: View {
    @Bindable var controller: KnowledgeBaseController
    @Bindable private var models = LocalModelManager.shared
    @FocusState private var inputFocused: Bool

    private var livePlan: LocalModelInstallPlan {
        models.knowledgeQAInstallPlan(
            answerModelID: KnowledgeQAModelPolicy.localAnswerModelID,
            includeReranker: KnowledgeQAModelPolicy.includeReranker
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            messages
            if let accessBlockedMessage = controller.accessBlockedMessage {
                accessBanner(accessBlockedMessage)
            } else if let qaBlockedMessage = controller.qaBlockedMessage {
                qaBlockedBanner(qaBlockedMessage)
            }
            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
            }
            modelGate
            composer
        }
        .background(AppTheme.Background.baseColor)
        .onAppear { controller.syncModelPlan(livePlan) }
        .onChange(of: livePlan) { _, newPlan in
            controller.syncModelPlan(newPlan)
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
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
            if controller.isAnswering {
                ProgressView()
                    .controlSize(.small)
                if let statusText = controller.statusText {
                    Text(statusText)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Button(L10n.string("Stop")) {
                    controller.cancelAnswer()
                }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if let modelStatusText = controller.modelStatusText {
                Text(modelStatusText)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: AppTheme.Workbench.toolbarHeight)
        .background(AppTheme.Background.surfaceColor)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if controller.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, AppTheme.Spacing.xxl)
                    }
                    ForEach(controller.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .onChange(of: controller.messages.last?.content) { _, _ in
                guard let lastID = controller.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(L10n.string("Ask your knowledge base"))
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string("Select All knowledge to search across sessions, or pick one session for focused QA."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
    }

    private func messageBubble(_ message: KnowledgeMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if isUser {
                    Text(message.content)
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .textSelection(.enabled)
                } else {
                    MarkdownText(
                        text: message.content.isEmpty && message.isStreaming ? "…" : message.content,
                        proseFont: .system(size: AppTheme.FontSize.smMd)
                    )
                    if !message.citations.isEmpty {
                        citationRow(message.citations)
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(
                        isUser
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                            : AppTheme.Background.surfaceColor
                    )
            )
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private func citationRow(_ citations: [KnowledgeSourceRef]) -> some View {
        FlowCitationChips(citations: citations) { ref in
            CitationResolver.open(ref)
        }
    }

    private func accessBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "lock.fill")
            Text(message)
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
            Text(message)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Background.surfaceColor)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
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
        HStack(alignment: .bottom, spacing: AppTheme.Spacing.md) {
            TextField(L10n.string("Ask a question…"), text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { controller.send() }
                .disabled(controller.accessBlockedMessage != nil || !controller.canAskCurrentScope)

            Button {
                controller.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canSend ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(L10n.string("Send"))
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor)
    }

    private var canSend: Bool {
        !controller.isAnswering
            && !controller.isPreparingKnowledgeModels
            && controller.accessBlockedMessage == nil
            && controller.canAskCurrentScope
            && !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Simple wrapping chip row without pulling in a layout dependency.
private struct FlowCitationChips: View {
    let citations: [KnowledgeSourceRef]
    let onTap: (KnowledgeSourceRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(citations.prefix(8)) { ref in
                Button {
                    onTap(ref)
                } label: {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "link")
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        Text(ref.chipLabel)
                            .lineLimit(1)
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.string("Open session"))
            }
        }
    }
}
