import SwiftUI

struct EditorDubSheet: View {
    let request: EditorDubRequest
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var referenceMode: EditorDubReferenceMode = .library
    @State private var referenceVoiceID: UUID?
    @State private var referenceClipID: String?
    @State private var referenceRange: ClosedRange<Double> = 0...1
    @State private var recorder = VoiceRecorderController()

    private var audioClips: [Clip] {
        editor.timeline.tracks
            .flatMap(\.clips)
            .filter { $0.mediaType.isAudio }
    }

    private var selectedReferenceClip: Clip? {
        guard let referenceClipID else { return nil }
        return audioClips.first { $0.id == referenceClipID }
    }

    private var selectedReferenceURL: URL? {
        selectedReferenceClip.flatMap { editor.mediaAssetsById[$0.mediaRef]?.url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("Create dub"))
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))

            Text(L10n.string("Write the script and choose a reference voice. The result will be placed on a dedicated dub track."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("Script"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                TextEditor(text: $script)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .frame(minHeight: AppTheme.EditorPanel.textEditorMinHeight)
                    .padding(AppTheme.Spacing.xs)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    }
            }

            Picker(L10n.string("Reference"), selection: $referenceMode) {
                Text(L10n.string("Voice library")).tag(EditorDubReferenceMode.library)
                Text(L10n.string("Record")).tag(EditorDubReferenceMode.recording)
                Text(L10n.string("Timeline audio")).tag(EditorDubReferenceMode.timelineClip)
            }
            .pickerStyle(.segmented)

            referenceContent

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Generate dub")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.Workbench.dubSheetWidth)
        .onChange(of: referenceClipID, initial: true) { _, _ in
            updateReferenceRange()
        }
    }

    @ViewBuilder
    private var referenceContent: some View {
        switch referenceMode {
        case .library:
            VoiceReferencePicker(
                selection: $referenceVoiceID,
                languageCode: "auto"
            )
        case .recording:
            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    if recorder.isRecording {
                        recorder.stop()
                    } else {
                        recorder.start()
                    }
                } label: {
                    Label(
                        recorder.isRecording ? L10n.string("Stop recording") : L10n.string("Record reference"),
                        systemImage: recorder.isRecording ? "stop.fill" : "mic.fill"
                    )
                }
                .buttonStyle(.bordered)
                if recorder.isRecording {
                    Text(recorder.duration, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else if recorder.recordedURL != nil {
                    Label(L10n.string("Reference recorded"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Status.successColor)
                }
            }
        case .timelineClip:
            Picker(L10n.string("Audio clip"), selection: $referenceClipID) {
                Text(L10n.string("Choose an audio clip")).tag(nil as String?)
                ForEach(audioClips) { clip in
                    Text(clipLabel(clip)).tag(clip.id as String?)
                }
            }
            if let selectedReferenceURL {
                ClipRangeControl(mediaURL: selectedReferenceURL, range: $referenceRange)
            }
        }
    }

    private var canStart: Bool {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch referenceMode {
        case .library:
            return true
        case .recording:
            return recorder.recordedURL != nil && !recorder.isRecording
        case .timelineClip:
            return selectedReferenceClip != nil && selectedReferenceURL != nil
        }
    }

    private func clipLabel(_ clip: Clip) -> String {
        let name = editor.mediaAssetsById[clip.mediaRef]?.name ?? clip.mediaRef
        return "\(name) · \(clip.startFrame)"
    }

    private func updateReferenceRange() {
        guard let clip = selectedReferenceClip else {
            referenceRange = 0...1
            return
        }
        let fps = Double(max(1, editor.timeline.fps))
        let start = Double(clip.trimStartFrame) / fps
        let end = start + Double(max(1, clip.sourceFramesConsumed)) / fps
        referenceRange = start...max(start + 0.25, end)
    }

    private func start() {
        guard canStart else { return }
        editor.beginEditorDub(
            for: request.clipId,
            script: script,
            referenceMode: referenceMode,
            referenceVoiceID: referenceVoiceID,
            recordedURL: recorder.recordedURL,
            referenceClipID: referenceClipID,
            referenceRange: referenceRange
        )
        dismiss()
    }
}
