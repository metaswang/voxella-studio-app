import SwiftUI

struct KnowledgeChatPane: View {
    @Bindable var controller: KnowledgeBaseController
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var llmSettings = LLMSettingsStore.shared
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
        .background(AppTheme.Background.baseColor)
        .onAppear { controller.syncModelPlan(livePlan) }
        .onChange(of: livePlan) { _, newPlan in
            controller.syncModelPlan(newPlan)
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "sparkles")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Accent.primary)
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
                Group {
                    if controller.isClearingHistory {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.string("Clear"))
                        }
                    } else {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "broom.fill")
                            Text(L10n.string("Clear"))
                        }
                    }
                }
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.baseColor)
            )
            .disabled(controller.messages.isEmpty || controller.isAnswering || controller.isClearingHistory)
            .accessibilityLabel(L10n.string("Clear chat history"))
            .help(L10n.string("Clear chat history"))
            if controller.isAnswering {
                KnowledgeAnswerStatusControl(
                    status: controller.statusText ?? L10n.string("Working…"),
                    onStop: controller.cancelAnswer
                )
            } else if let modelStatusText = controller.modelStatusText {
                Text(modelStatusText)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
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
                            .frame(maxWidth: .infinity)
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(systemName: "text.bubble")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .padding(AppTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
                    )

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Ask your knowledge base"))
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("Select All knowledge to search across sessions, or pick one session for focused QA."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
                    GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
                ],
                spacing: AppTheme.Spacing.sm
            ) {
                ForEach(Self.starterPrompts) { prompt in
                    Button {
                        controller.draft = L10n.string(prompt.titleKey)
                        inputFocused = true
                    } label: {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: prompt.icon)
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                                .foregroundStyle(AppTheme.Accent.primary)
                                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                            Text(L10n.string(prompt.titleKey))
                                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: AppTheme.Spacing.zero)
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: AppTheme.Knowledge.starterPromptMinHeight,
                            alignment: .leading
                        )
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                                .fill(AppTheme.Background.surfaceColor)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: AppTheme.Knowledge.emptyStateMaxWidth, alignment: .leading)
        .padding(AppTheme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        }
        .shadow(AppTheme.Shadow.sm)
    }

    private func messageBubble(_ message: KnowledgeMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: AppTheme.Spacing.xxl) }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if isUser {
                    Text(message.content)
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .textSelection(.enabled)
                } else {
                    if message.content.isEmpty && message.isStreaming {
                        KnowledgeEmptyAnswerIndicator()
                    } else {
                        MarkdownText(
                            text: message.content,
                            proseFont: .system(size: AppTheme.FontSize.smMd)
                        )
                    }
                    if !message.citations.isEmpty {
                        citationRow(message.citations)
                    }
                    if !message.recoveryActions.isEmpty {
                        recoveryActions(message.recoveryActions)
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
            .frame(maxWidth: AppTheme.Knowledge.messageMaxWidth, alignment: .leading)
            if !isUser { Spacer(minLength: AppTheme.Spacing.xxl) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func citationRow(_ citations: [KnowledgeSourceRef]) -> some View {
        FlowCitationChips(citations: citations) { ref in
            controller.openCitation(ref)
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

    private func answerAvailabilityBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "sparkles.rectangle.stack")
            Text(message)
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
                Button(recoveryLabel(action)) {
                    controller.performRecoveryAction(action)
                }
                .buttonStyle(.borderless)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            }
        }
    }

    private func recoveryLabel(_ action: KnowledgeRecoveryAction) -> String {
        switch action {
        case .account: "Manage credits"
        case .aiSettings: "Configure BYOK"
        }
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
                modelBadge
                Spacer(minLength: AppTheme.Spacing.sm)
                if isBYOK {
                    reasoningPicker
                } else {
                    Label(L10n.string("Hosted AI"), systemImage: "cloud")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
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
        .background(AppTheme.Background.surfaceColor)
    }

    private var isBYOK: Bool {
        AITransportPolicy.current == .byok
    }

    private var modelBadge: some View {
        let model = isBYOK ? llmSettings.route(for: .chat).primaryModel : L10n.string("Hosted AI")
        return Label {
            Text(verbatim: model)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: isBYOK ? "key.fill" : "cloud")
        }
        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Chat model"))
        .accessibilityValue(Text(verbatim: model))
        .help(Text(verbatim: model))
    }

    private var reasoningPicker: some View {
        Menu {
            ForEach(LLMReasoningEffort.allCases) { effort in
                Button {
                    llmSettings.chatReasoningEffort = effort
                } label: {
                    if effort == llmSettings.chatReasoningEffort {
                        Label(L10n.string(key: effort.labelKey), systemImage: "checkmark")
                    } else {
                        Text(L10n.string(key: effort.labelKey))
                    }
                }
            }
        } label: {
            Label {
                Text(L10n.string(key: llmSettings.chatReasoningEffort.labelKey))
                    .lineLimit(1)
            } icon: {
                Image(systemName: "brain.head.profile")
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.string("Reasoning effort"))
        .accessibilityValue(L10n.string(key: llmSettings.chatReasoningEffort.labelKey))
        .help(L10n.string("Reasoning effort"))
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

/// Animated three-dot affordance for the gap between submitting a question and
/// receiving the first streamed token. Keeping the dots as separate glyphs
/// makes the motion read as an ellipsis rather than a generic spinner.
private struct KnowledgeEmptyAnswerIndicator: View {
    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            KnowledgeTypingIndicator()
            Text(L10n.string("Searching knowledge"))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("Searching knowledge"))
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
                    Text(status)
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
        .accessibilityLabel(Text("\(L10n.string("Answering")): \(status)"))
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

/// Simple wrapping chip row without pulling in a layout dependency.
private struct FlowCitationChips: View {
    let citations: [KnowledgeSourceRef]
    let onTap: (KnowledgeSourceRef) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: AppTheme.Spacing.xs)],
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
                            .lineLimit(1)
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.string("Open transcript"))
            }
        }
    }
}

private struct KnowledgeStarterPrompt: Identifiable {
    let icon: String
    let titleKey: String

    var id: String { titleKey }
}

private extension KnowledgeChatPane {
    static let starterPrompts = [
        KnowledgeStarterPrompt(icon: "text.badge.checkmark", titleKey: "Summarize recent sessions"),
        KnowledgeStarterPrompt(icon: "list.bullet.rectangle", titleKey: "Find key decisions"),
        KnowledgeStarterPrompt(icon: "checklist", titleKey: "List action items"),
        KnowledgeStarterPrompt(icon: "envelope", titleKey: "Draft follow-up questions"),
    ]
}
