import SwiftUI

struct SessionExportCenter: View {
    let session: WorkbenchSession
    let preferredContent: SessionExportContent?
    let onCancel: () -> Void

    @State private var draft: SessionExportDraft
    @State private var isExporting = false

    private var availability: SessionExportAvailability {
        SessionExportAvailability.from(session)
    }

    init(
        session: WorkbenchSession,
        preferredContent: SessionExportContent? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.preferredContent = preferredContent
        self.onCancel = onCancel
        let availability = SessionExportAvailability.from(session)
        _draft = State(
            initialValue: .default(for: availability, preferredContent: preferredContent)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        section("Content") {
                            choiceGrid(
                                items: contentChoices,
                                selection: draft.content
                            ) { content in
                                updateDraft { draft in
                                    draft.content = content
                                    draft.includeSpeakers = content == .transcript
                                    draft.includeTimestamps = content == .subtitle
                                    if content == .audio {
                                        draft.format = .audio
                                        draft.action = .download
                                    } else if draft.format == .audio {
                                        draft.format = .txt
                                    }
                                }
                            }
                        }

                        section("Variant") {
                            choiceGrid(
                                items: variantChoices,
                                selection: draft.variant
                            ) { variant in
                                updateDraft { $0.variant = variant }
                            }
                        }

                        if showsTargetLanguage {
                            section("Target language") {
                                choiceGrid(
                                    items: targetLanguageChoices,
                                    selection: draft.targetLanguage ?? targetLanguageChoices.first?.id
                                ) { code in
                                    updateDraft { $0.targetLanguage = code }
                                }
                            }
                        }

                        if draft.variant == .bilingual {
                            section("Translation order") {
                                choiceGrid(
                                    items: orderChoices,
                                    selection: draft.translationOrder
                                ) { order in
                                    updateDraft { $0.translationOrder = order }
                                }
                            }
                        }

                        section("Format") {
                            choiceGrid(
                                items: formatChoices,
                                selection: draft.format
                            ) { format in
                                updateDraft { $0.format = format }
                            }
                        }

                        if draft.content != .audio, draft.format == .txt {
                            section("Speaker labels") {
                                choiceGrid(
                                    items: speakerChoices,
                                    selection: draft.includeSpeakers ? "on" : "off"
                                ) { value in
                                    updateDraft { $0.includeSpeakers = value == "on" }
                                }
                            }
                        }

                        section("Action") {
                            choiceGrid(
                                items: actionChoices,
                                selection: draft.action
                            ) { action in
                                updateDraft { $0.action = action }
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.xl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                summaryPanel
                    .frame(width: AppTheme.Workbench.exportSummaryWidth)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(AppTheme.Border.subtleColor)
                            .frame(width: AppTheme.BorderWidth.thin)
                    }
            }
        }
        .frame(
            width: AppTheme.Workbench.exportSheetWidth,
            height: AppTheme.Workbench.exportSheetHeight
        )
        .background(AppTheme.Background.surfaceColor)
        .colorScheme(.dark)
        .disabled(isExporting)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Label("Export", systemImage: "square.and.arrow.down")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .labelStyle(.titleAndIcon)
                Text("Build the right export for the next step")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                Text("Choose content, format, language version, and output action.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .background(
                        AppTheme.Background.raisedColor,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
            }
            .buttonStyle(.plain)
            .help("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(AppTheme.Spacing.xl)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.thin)
        }
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("READY TO EXPORT")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Accent.primary)
                .tracking(1.2)

            Text(primaryActionTitle)
                .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(draft.summaryLabel)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                if let target = selectedTargetLabel {
                    Text("Target: \(target)")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if draft.content != .audio, draft.format == .txt {
                    Text(draft.includeSpeakers ? "With speaker labels" : "Without speaker labels")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppTheme.Background.raisedColor,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            ForEach(summaryNotes, id: \.self) { note in
                HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                    Circle()
                        .fill(AppTheme.Accent.primary)
                        .frame(width: AppTheme.Spacing.xs, height: AppTheme.Spacing.xs)
                        .padding(.top, AppTheme.Spacing.sm)
                    Text(note)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppTheme.Spacing.zero)

            Button {
                Task { await runExport() }
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: draft.action.systemImage)
                    }
                    Text(isExporting ? progressTitle : primaryActionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isExporting || !canExport)
            .keyboardShortcut(.defaultAction)

            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.muted))
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .tracking(1.4)
            content()
        }
    }

    private func choiceGrid<ID: Hashable>(
        items: [SessionExportChoice<ID>],
        selection: ID?,
        onSelect: @escaping (ID) -> Void
    ) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.md),
            count: min(max(items.count, 1), 3)
        )
        return LazyVGrid(columns: columns, spacing: AppTheme.Spacing.md) {
            ForEach(items) { item in
                Button {
                    guard !item.disabled else { return }
                    onSelect(item.id)
                } label: {
                    choiceCard(item, selected: selection == item.id)
                }
                .buttonStyle(.plain)
                .disabled(item.disabled)
            }
        }
    }

    private func choiceCard<ID: Hashable>(
        _ item: SessionExportChoice<ID>,
        selected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack {
                Image(systemName: item.systemImage)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(selected ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                    .background(
                        (selected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft) : AppTheme.Background.raisedColor),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Accent.primary)
                    .opacity(selected ? AppTheme.Opacity.opaque : AppTheme.Opacity.zero)
            }
            Text(item.title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .multilineTextAlignment(.leading)
            if let hint = item.hint {
                Text(hint)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.exportChoiceMinHeight, alignment: .topLeading)
        .background(
            selected ? AppTheme.Background.raisedColor : AppTheme.Background.baseColor.opacity(AppTheme.Opacity.muted),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(
                    selected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium) : AppTheme.Border.subtleColor,
                    lineWidth: selected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                )
        }
        .opacity(item.disabled ? AppTheme.Opacity.muted : AppTheme.Opacity.opaque)
    }

    private var contentChoices: [SessionExportChoice<SessionExportContent>] {
        [
            .init(
                id: .transcript,
                title: SessionExportContent.transcript.title,
                hint: SessionExportContent.transcript.hint,
                systemImage: SessionExportContent.transcript.systemImage,
                disabled: !availability.transcript
            ),
            .init(
                id: .subtitle,
                title: SessionExportContent.subtitle.title,
                hint: SessionExportContent.subtitle.hint,
                systemImage: SessionExportContent.subtitle.systemImage,
                disabled: !availability.subtitle
            ),
            .init(
                id: .audio,
                title: SessionExportContent.audio.title,
                hint: SessionExportContent.audio.hint,
                systemImage: SessionExportContent.audio.systemImage,
                disabled: !availability.audio && !availability.dubbedAudio
            ),
        ]
    }

    private var variantChoices: [SessionExportChoice<SessionExportVariant>] {
        switch draft.content {
        case .audio:
            var choices: [SessionExportChoice<SessionExportVariant>] = [
                .init(
                    id: .original,
                    title: "Original",
                    hint: "The original source audio.",
                    systemImage: "waveform",
                    disabled: !availability.audio
                ),
            ]
            if availability.dubbedAudio {
                choices.append(
                    .init(
                        id: .dub,
                        title: "Dubbed Audio",
                        hint: "The generated dubbed track.",
                        systemImage: "waveform.and.mic"
                    )
                )
            }
            return choices
        case .subtitle:
            var choices: [SessionExportChoice<SessionExportVariant>] = [
                .init(
                    id: .original,
                    title: "Original",
                    hint: "Keep only the source-language captions.",
                    systemImage: "doc.plaintext"
                ),
            ]
            if availability.hasTranslation {
                choices.append(
                    .init(
                        id: .translation,
                        title: "Translation",
                        hint: "Choose one target-language subtitle track.",
                        systemImage: "globe"
                    )
                )
            }
            return choices
        case .transcript:
            var choices: [SessionExportChoice<SessionExportVariant>] = [
                .init(
                    id: .original,
                    title: "Original",
                    hint: availability.hasTranslation
                        ? "Keep only the source language text."
                        : nil,
                    systemImage: "doc.plaintext"
                ),
            ]
            if availability.hasTranslation {
                choices.append(
                    contentsOf: [
                        .init(
                            id: .translation,
                            title: "Translation",
                            hint: "Export only the translated text.",
                            systemImage: "globe"
                        ),
                        .init(
                            id: .bilingual,
                            title: "Bilingual",
                            hint: "Export source and translation together.",
                            systemImage: "arrow.left.arrow.right"
                        ),
                    ]
                )
            }
            return choices
        }
    }

    private var formatChoices: [SessionExportChoice<SessionExportFormat>] {
        if draft.content == .audio {
            return [
                .init(
                    id: .audio,
                    title: "Audio",
                    hint: "Download the source or dubbed audio file.",
                    systemImage: "waveform"
                ),
            ]
        }
        return [
            .init(id: .txt, title: "TXT", hint: "Plain text for sharing and reuse.", systemImage: "textformat"),
            .init(id: .vtt, title: "VTT", hint: "Best for web and player workflows.", systemImage: "captions.bubble"),
            .init(id: .srt, title: "SRT", hint: "Best for editors and subtitle platforms.", systemImage: "doc.text"),
        ]
    }

    private var actionChoices: [SessionExportChoice<SessionExportAction>] {
        [
            .init(
                id: .download,
                title: "Download",
                hint: "Save a file locally for editing, upload, or archive.",
                systemImage: "square.and.arrow.down"
            ),
            .init(
                id: .copy,
                title: "Copy",
                hint: "Send the text directly to your clipboard.",
                systemImage: "doc.on.doc",
                disabled: draft.content == .audio
            ),
        ]
    }

    private var orderChoices: [SessionExportChoice<SessionExportTranslationOrder>] {
        SessionExportTranslationOrder.allCases.map {
            .init(id: $0, title: $0.title, hint: $0.hint, systemImage: $0 == .translationFirst ? "globe" : "doc.plaintext")
        }
    }

    private var speakerChoices: [SessionExportChoice<String>] {
        [
            .init(
                id: "on",
                title: "With speaker labels",
                hint: "Prefix each text block with the speaker name when available.",
                systemImage: "person.wave.2"
            ),
            .init(
                id: "off",
                title: "Without speaker labels",
                hint: "Export clean text only, without speaker prefixes.",
                systemImage: "text.alignleft"
            ),
        ]
    }

    private var targetLanguageChoices: [SessionExportChoice<String>] {
        availability.translationTracks.map {
            .init(
                id: $0.languageCode,
                title: $0.displayLanguageLabel,
                hint: "\($0.track.cues.count) cues",
                systemImage: "globe"
            )
        }
    }

    private var showsTargetLanguage: Bool {
        guard availability.hasTranslation else { return false }
        if draft.content == .subtitle, draft.variant == .translation { return true }
        if draft.content == .transcript, draft.variant == .translation || draft.variant == .bilingual {
            return true
        }
        return false
    }

    private var selectedTargetLabel: String? {
        guard let code = draft.targetLanguage else { return nil }
        return availability.translationTracks.first {
            $0.languageCode.caseInsensitiveCompare(code) == .orderedSame
        }?.displayLanguageLabel
    }

    private var primaryActionTitle: String {
        if draft.action == .copy {
            return "Copy \(draft.format.title)"
        }
        if draft.content == .audio {
            return "Download Audio"
        }
        return "Download \(draft.format.title)"
    }

    private var progressTitle: String {
        draft.action == .copy ? "Copying…" : "Saving…"
    }

    private var canExport: Bool {
        switch draft.content {
        case .transcript: availability.transcript
        case .subtitle: availability.subtitle
        case .audio: draft.variant == .dub ? availability.dubbedAudio : availability.audio
        }
    }

    private var summaryNotes: [String] {
        switch draft.content {
        case .audio:
            return [
                "Audio export copies the local source or dubbed file without re-encoding.",
                "Use Original for the imported media, or Dubbed Audio after a dub completes.",
            ]
        case .subtitle:
            return [
                draft.format == .srt
                    ? "SRT remains the safest handoff format for editors and publishing platforms."
                    : draft.format == .vtt
                        ? "VTT is strongest for web players and browser-first delivery."
                        : "TXT is fastest for copy-paste workflows and document cleanup.",
                "Subtitle export uses fine-grained cues, matching the Subtitles tab.",
            ]
        case .transcript:
            return [
                draft.format == .txt
                    ? "TXT is fastest for copy-paste workflows and document cleanup."
                    : "Timed transcript export uses aggregated session segments.",
                draft.variant == .bilingual
                    ? "Bilingual export preserves both lines together for review."
                    : "Original and translation stay independent of subtitle cue edits.",
            ]
        }
    }

    private func updateDraft(_ mutate: (inout SessionExportDraft) -> Void) {
        var next = draft
        mutate(&next)
        next.normalize(against: availability)
        draft = next
    }

    private func runExport() async {
        isExporting = true
        defer { isExporting = false }
        var normalized = draft
        normalized.normalize(against: availability)
        draft = normalized
        do {
            _ = try await SessionExportRunner.run(session: session, draft: normalized)
            onCancel()
        } catch let error as SessionExportError where error == .cancelled {
            return
        } catch {
            WorkbenchTipCenter.shared.show(
                error.localizedDescription,
                kind: .error,
                id: "session.export.failed.\(session.id.uuidString)"
            )
        }
    }
}

private struct SessionExportChoice<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let hint: String?
    let systemImage: String
    var disabled = false

    init(
        id: ID,
        title: String,
        hint: String? = nil,
        systemImage: String,
        disabled: Bool = false
    ) {
        self.id = id
        self.title = title
        self.hint = hint
        self.systemImage = systemImage
        self.disabled = disabled
    }
}
