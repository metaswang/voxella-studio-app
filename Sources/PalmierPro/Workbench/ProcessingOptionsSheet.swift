import SwiftUI

struct ProcessingOptionsSheet: View {
    let mediaURLs: [URL]
    let onCancel: () -> Void
    let onContinue: (LocalProcessingOptions) -> Void

    @State private var languageCode: String? = WorkbenchTranscriptionLanguage.automatic.languageCode
    @State private var showAdvanced = false
    @State private var speakerCount: SpeakerCountOption = .auto
    @State private var enableClip = false
    @State private var clipRange: ClosedRange<Double> = 0...1
    @State private var enableTranslation = false
    @State private var targetLanguageCode = ""
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var llmSettings = LLMSettingsStore.shared

    private var isSingleFile: Bool { mediaURLs.count == 1 }
    private var continueDisabled: Bool {
        enableTranslation && targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    fileSummary
                    languageField
                    advancedToggle
                    if showAdvanced {
                        advancedSection
                    }
                    modelHint
                }
                .padding(AppTheme.Spacing.xl)
            }
            footer
        }
        .frame(width: 560, height: 620)
        .background(AppTheme.Background.surfaceColor)
        .colorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Processing options")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text("Optionally clip the audio and enable translation before processing.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.xl)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var fileSummary: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: mediaURLs.count > 1 ? "doc.on.doc" : "doc")
                .foregroundStyle(Color.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(mediaURLs.count == 1
                      ? mediaURLs[0].lastPathComponent
                      : "\(mediaURLs.count) files selected")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                Text(mediaURLs.count > 1
                      ? "Files are processed one at a time on this Mac to protect memory and GPU."
                      : mediaURLs[0].path)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.65), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private var languageField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input language")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            Menu {
                ForEach(WorkbenchTranscriptionLanguage.allCases) { option in
                    Button {
                        languageCode = option.languageCode
                    } label: {
                        menuItemLabel(option.label, selected: languageCode == option.languageCode)
                    }
                }
            } label: {
                processingMenuLabel(selectedLanguageLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var selectedLanguageLabel: String {
        WorkbenchTranscriptionLanguage.allCases
            .first(where: { $0.languageCode == languageCode })?
            .label ?? WorkbenchTranscriptionLanguage.automatic.label
    }

    private func processingMenuLabel(_ title: String) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.sm)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
        }
        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(width: AppTheme.Workbench.pickerWidth, height: AppTheme.IconSize.lg, alignment: .leading)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .contentShape(Rectangle())
    }

    private func menuItemLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                showAdvanced.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                Text("Advanced settings")
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            .foregroundStyle(Color.indigo)
        }
        .buttonStyle(.plain)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker count")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                Menu {
                    ForEach(SpeakerCountOption.allCases) { option in
                        Button {
                            speakerCount = option
                        } label: {
                            menuItemLabel(option.label, selected: speakerCount == option)
                        }
                    }
                } label: {
                    processingMenuLabel(speakerCount.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            if isSingleFile {
                clipSection
            }

            translationSection
        }
        .padding(.top, AppTheme.Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Toggle(isOn: $enableClip) {
                Text("Clip (optional)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            }
            .toggleStyle(.checkbox)
            if enableClip {
                Text("Select a time range to process.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                ClipRangeControl(mediaURL: mediaURLs[0], range: $clipRange)
                    .padding(AppTheme.Spacing.md)
                    .background(AppTheme.Background.baseColor.opacity(0.45), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.45), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Toggle(isOn: $enableTranslation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable translation")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    Text("Translate the transcript to the selected language when enabled.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .toggleStyle(.checkbox)

            if enableTranslation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target language")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    Menu {
                        Button {
                            targetLanguageCode = ""
                        } label: {
                            menuItemLabel("Select language", selected: targetLanguageCode.isEmpty)
                        }
                        ForEach(WorkbenchTranscriptionLanguage.allCases.filter {
                            $0.languageCode != nil && $0.languageCode != languageCode
                        }) { option in
                            Button {
                                targetLanguageCode = option.languageCode ?? ""
                            } label: {
                                menuItemLabel(
                                    option.label,
                                    selected: targetLanguageCode == option.languageCode
                                )
                            }
                        }
                    } label: {
                        processingMenuLabel(targetLanguageLabel)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.45), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
        }
        .onChange(of: enableTranslation) { _, enabled in
            if !enabled { targetLanguageCode = "" }
            else if showAdvanced == false { showAdvanced = true }
        }
    }

    private var targetLanguageLabel: String {
        guard !targetLanguageCode.isEmpty else { return "Select language" }
        return WorkbenchTranscriptionLanguage.allCases
            .first(where: { $0.languageCode == targetLanguageCode })?
            .label ?? "Select language"
    }

    private var modelHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gearshape.2")
                .foregroundStyle(Color.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text("ASR and translation models are configured in Settings.")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                Text("Active ASR: \(models.descriptor(for: models.activeASRModelID).title). Translation uses \(llmSettings.route(for: .translation).primaryModel).")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Button("AI Settings…") {
                    SettingsWindowController.shared.show(tab: .ai)
                }
                .buttonStyle(.borderless)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            }
            Spacer()
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.14), Color.cyan.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Continue") {
                var options = LocalProcessingOptions(
                    languageCode: languageCode,
                    speakerCount: speakerCount,
                    enableTranslation: enableTranslation,
                    targetLanguageCode: enableTranslation ? targetLanguageCode : nil
                )
                if isSingleFile, enableClip {
                    options.clipStartMs = Int((clipRange.lowerBound * 1000).rounded())
                    options.clipEndMs = Int((clipRange.upperBound * 1000).rounded())
                }
                onContinue(options)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(continueDisabled)
            .keyboardShortcut(.defaultAction)
        }
        .padding(AppTheme.Spacing.xl)
        .background(AppTheme.Background.surfaceColor.opacity(0.96))
        .overlay(alignment: .top) { Divider() }
    }
}
