import SwiftUI

struct SpeechTab: View {
    @Environment(EditorViewModel.self) private var editor
    @Bindable private var models = LocalModelManager.shared

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                    speakersSection
                    silenceSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let phase = editor.speakerIdentifyPhase {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: phase, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var speakersSection: some View {
        EditorPanelGroup("Speakers") {
            InspectorRow(
                label: "Mark Speakers",
                labelHelp: "Tints waveforms by speaker using local transcripts and on-device voice embeddings.",
                onReset: { editor.markSpeakers = false }
            ) {
                Toggle("", isOn: Binding(
                    get: { editor.markSpeakers },
                    set: { editor.markSpeakers = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Mark Speakers"))
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                if models.hasRequiredModels(for: .transcribe) {
                    Button(L10n.string(editor.projectSpeakers.isEmpty ? "Identify Speakers" : "Refresh")) {
                        editor.identifySpeakers(transcribeMissing: true)
                    }
                    .controlSize(.small)
                    .disabled(editor.speakerIdentifyInFlight)
                    .help(L10n.string("Matches voices across clips on this Mac. Local transcripts and voice fingerprints are cached, so re-runs are fast."))
                } else {
                    Button(L10n.string("Prepare Local Features…")) { models.presentManager() }
                        .controlSize(.small)
                    Text(L10n.string("Required for speaker detection"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            if let error = editor.speakerIdentifyError {
                Text(L10n.display(error))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !editor.projectSpeakers.isEmpty {
                Text(L10n.string("Labels"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.xs)
            }
            ForEach(editor.projectSpeakers) { speaker in
                HStack(spacing: AppTheme.Spacing.sm) {
                    ColorPicker("", selection: Binding(
                        get: { editor.projectSpeakers.first(where: { $0.id == speaker.id })?.color ?? speaker.color },
                        set: { editor.setSpeakerColor(id: speaker.id, color: $0) }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                    TextField(L10n.string("Name"), text: Binding(
                        get: { editor.projectSpeakers.first(where: { $0.id == speaker.id })?.name ?? speaker.name },
                        set: { editor.renameSpeaker(id: speaker.id, name: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.sm))
                    Button {
                        editor.removeSpeaker(id: speaker.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Removes this label and tint. Identify recreates it if the voice is still present."))
                }
            }
        }
    }

    private var silenceSection: some View {
        EditorPanelGroup("Silence Detection") {
            InspectorRow(
                label: "Mark Silence",
                labelHelp: "Speech is detected on-device in the background. Dims quiet, speech-free spans on timeline waveforms.",
                onReset: { editor.markDeadAir = false }
            ) {
                Toggle("", isOn: Binding(
                    get: { editor.markDeadAir },
                    set: { editor.markDeadAir = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Mark Silence"))
            }
            if editor.speechAnalyzingCount > 0 {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(editor.speechAnalyzingCount == 1
                        ? L10n.string("Detecting speech…")
                        : L10n.format("Detecting speech in %@ files…", editor.speechAnalyzingCount))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            removeSilenceRow
        }
    }

    private var removeSilenceRow: some View {
        let count = editor.allDeadAir().reduce(0) { $0 + $1.ranges.count }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Button(L10n.string("Remove Silence")) { editor.removeAllDeadAir() }
                .controlSize(.small)
                .disabled(count == 0)
                .help(L10n.string("Ripple-deletes every silent section; downstream clips close the gaps."))
            if count > 0 {
                Text(count == 1 ? L10n.string("1 section") : L10n.format("%@ sections", count))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }
}
