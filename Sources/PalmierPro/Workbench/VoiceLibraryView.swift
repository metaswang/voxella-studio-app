import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceLibraryView: View {
    @Bindable private var store = VoiceLibraryStore.shared
    @State private var showComposer = false
    @State private var languageFilter = "all"
    @State private var editingReference: LocalVoiceReference?

    private var filteredReferences: [LocalVoiceReference] {
        guard languageFilter != "all" else { return store.references }
        return store.references.filter { $0.languageCode == languageFilter }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                header
                if showComposer {
                    NewVoiceReferenceComposer {
                        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                            showComposer = false
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                library
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Background.baseColor)
        .sheet(item: $editingReference) { reference in
            VoiceReferenceEditSheet(reference: reference)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Voice library")
                    .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                Text("Manage local reference voices and reuse them across dubbing sessions.")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            HStack(spacing: AppTheme.Spacing.smMd) {
                summaryBadge("Custom \(store.references.count)", systemImage: "person.crop.circle.badge.checkmark")
                summaryBadge(
                    "Default \(store.references.filter(\.isDefault).count)",
                    systemImage: "star"
                )
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                        showComposer.toggle()
                    }
                } label: {
                    Label(showComposer ? "Hide new reference" : "New reference", systemImage: showComposer ? "xmark" : "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .background(
            LinearGradient(
                colors: [
                    AppTheme.Background.surfaceColor,
                    AppTheme.Background.raisedColor,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func summaryBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(AppTheme.Background.raisedColor, in: Capsule())
            .overlay { Capsule().strokeBorder(AppTheme.Border.subtleColor) }
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("My references")
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    Text("Filter, preview, and manage voices stored on this Mac.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                Picker("Language", selection: $languageFilter) {
                    Text("All languages").tag("all")
                    Divider()
                    ForEach(WorkbenchDubLanguage.allCases.filter { $0 != .automatic }) { language in
                        Text(language.label).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: AppTheme.Workbench.filterWidth)
            }
            .padding(AppTheme.Spacing.lgXl)

            Divider()

            VStack(spacing: AppTheme.Spacing.mdLg) {
                modelDefaultRow
                if store.isLoading {
                    ProgressView("Loading local voices…")
                        .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.voiceRowMinHeight)
                } else if filteredReferences.isEmpty {
                    ContentUnavailableView(
                        "No matching references",
                        systemImage: "waveform.badge.plus",
                        description: Text("Create a reference from a clean recording or audio file.")
                    )
                    .frame(minHeight: AppTheme.Workbench.voiceRowMinHeight * 2)
                } else {
                    ForEach(filteredReferences) { reference in
                        voiceRow(reference)
                    }
                }
            }
            .padding(AppTheme.Spacing.lgXl)
        }
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var modelDefaultRow: some View {
        HStack(spacing: AppTheme.Spacing.mdLg) {
            VoiceAvatarView(URL: nil, fallback: "V")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Built-in")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Status.successColor)
                    Text("Model default voice")
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                }
                Text("Used when no custom language default or session voice is selected.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            Text("Local")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(minHeight: AppTheme.Workbench.voiceRowMinHeight)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func voiceRow(_ reference: LocalVoiceReference) -> some View {
        HStack(spacing: AppTheme.Spacing.mdLg) {
            VoiceAvatarView(URL: store.avatarURL(for: reference), fallback: String(reference.name.prefix(1)))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Custom")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Accent.link)
                    Text(reference.gender.label)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    if reference.isDefault {
                        Label("Default", systemImage: "star.fill")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Accent.timecodeColor)
                    }
                }
                Text(reference.name)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                if !reference.transcript.isEmpty {
                    Text(reference.transcript)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Text("\(languageLabel(reference.languageCode)) · \(reference.duration.formatted(.number.precision(.fractionLength(1))))s · \(reference.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            Spacer()
            Button {
                store.togglePlayback(reference)
            } label: {
                Label(store.playingID == reference.id ? "Stop" : "Play", systemImage: store.playingID == reference.id ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            Button(reference.isDefault ? "Current default" : "Set as default") {
                Task { try? await store.setDefault(reference.id) }
            }
            .buttonStyle(.bordered)
            .disabled(reference.isDefault)
            Menu {
                Button("Edit") { editingReference = reference }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: reference)])
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await store.delete(reference.id)
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(minHeight: AppTheme.Workbench.voiceRowMinHeight)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func languageLabel(_ code: String) -> String {
        WorkbenchDubLanguage(rawValue: code)?.label
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }
}

private struct NewVoiceReferenceComposer: View {
    @Bindable private var store = VoiceLibraryStore.shared
    @State private var recorder = VoiceRecorderController()
    @State private var name = ""
    @State private var language = WorkbenchDubLanguage.english
    @State private var gender = VoiceReferenceGender.female
    @State private var transcript = ""
    @State private var audioURL: URL?
    @State private var avatarURL: URL?
    @State private var isSaving = false

    let onSaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("New reference voice")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                Text("Use a clean spoken clip. Audio is converted to 24 kHz mono without trimming or changing its duration.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            HStack(spacing: AppTheme.Spacing.mdLg) {
                stepCard("STEP 1", title: "Capture reference audio", detail: "Import a clip or record until you choose to stop.")
                stepCard("STEP 2", title: "Add the spoken script", detail: "Type the exact words or recognize them locally with ASR.")
            }

            HStack(alignment: .top, spacing: AppTheme.Spacing.lgXl) {
                field("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(WorkbenchDubLanguage.allCases.filter { $0 != .automatic }) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                }
                field("Gender") {
                    Picker("Gender", selection: $gender) {
                        ForEach(VoiceReferenceGender.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                }
                field("Name") {
                    TextField("Name this reference voice", text: $name)
                }
            }

            ReferenceScriptEditor(
                transcript: $transcript,
                audioURL: audioURL,
                languageCode: language.rawValue,
                isDisabled: recorder.isRecording || isSaving
            )

            HStack(spacing: AppTheme.Spacing.mdLg) {
                VoiceAvatarView(URL: avatarURL, fallback: name.isEmpty ? "A" : String(name.prefix(1)))
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Avatar (optional)")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                    Text("PNG, JPEG, or WebP up to 2 MB.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                Button(avatarURL == nil ? "Choose avatar…" : "Replace avatar…") {
                    chooseAvatar()
                }
                if avatarURL != nil {
                    Button("Clear") { avatarURL = nil }
                        .buttonStyle(.borderless)
                }
            }
            .padding(AppTheme.Spacing.lgXl)
            .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    chooseAudio()
                } label: {
                    Label(audioURL == nil ? "Choose file…" : "Replace file…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    recorder.isRecording ? recorder.stop() : recorder.start()
                } label: {
                    Label(
                        recorder.isRecording ? "Stop and use recording" : "Start recording",
                        systemImage: recorder.isRecording ? "stop.circle" : "mic"
                    )
                }
                .buttonStyle(.bordered)
                if recorder.isRecording {
                    Text("\(recorder.duration.formatted(.number.precision(.fractionLength(1))))s")
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Status.errorColor)
                } else if let audioURL {
                    Label(audioURL.lastPathComponent, systemImage: "waveform")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Spacer()
                Button("Save reference") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(audioURL == nil || recorder.isRecording || isSaving)
            }

            if let error = recorder.errorMessage ?? store.errorMessage {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Status.errorColor)
                    if recorder.needsMicrophoneSettings {
                        Button("Open System Settings") {
                            recorder.openMicrophoneSettings()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .onChange(of: recorder.recordedURL) { _, next in
            if let next { audioURL = next }
        }
        .onDisappear { recorder.cancel() }
    }

    private func stepCard(_ eyebrow: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(eyebrow)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(title)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            Text(detail)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseAudio() {
        Task {
            if let URL = await WorkbenchFilePicker.pickAudio(title: "Choose a clean voice reference") {
                recorder.cancel()
                audioURL = URL
            }
        }
    }

    private func chooseAvatar() {
        Task {
            let panel = NSOpenPanel()
            panel.title = "Choose an avatar"
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.png, .jpeg, .webP]
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            if response == .OK { avatarURL = panel.url }
        }
    }

    private func save() {
        guard let audioURL else { return }
        isSaving = true
        store.errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await store.create(VoiceReferenceDraft(
                    name: name,
                    languageCode: language.rawValue,
                    gender: gender,
                    transcript: transcript,
                    sourceAudioURL: audioURL,
                    avatarURL: avatarURL
                ))
                recorder.cancel()
                onSaved()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

@Observable
@MainActor
private final class ReferenceScriptRecognitionController {
    enum State: Equatable {
        case idle
        case recognizing(fraction: Double, message: String)
        case recognized
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var attemptID: UUID?

    var isRecognizing: Bool {
        if case .recognizing = state { return true }
        return false
    }

    func start(
        sourceURL: URL,
        languageCode: String,
        onRecognized: @escaping @MainActor (String) -> Void
    ) {
        guard !isRecognizing else { return }
        let models = LocalModelManager.shared
        guard models.hasRequiredTranscriptionModels(languageCode: languageCode, speakerCount: 1) else {
            state = .failed("Install the local ASR, alignment, and voice-activity models to recognize this script.")
            models.presentManager()
            return
        }

        let currentAttemptID = UUID()
        attemptID = currentAttemptID
        state = .recognizing(fraction: 0, message: "Preparing local recognition…")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await VoiceReferenceScriptRecognizer.shared.recognize(
                    sourceURL: sourceURL,
                    languageCode: languageCode,
                    progress: { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.attemptID == currentAttemptID else { return }
                            self.state = .recognizing(
                                fraction: update.fraction,
                                message: update.message
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                guard attemptID == currentAttemptID else { return }
                onRecognized(text)
                state = .recognized
                attemptID = nil
                task = nil
            } catch is CancellationError {
                guard attemptID == currentAttemptID else { return }
                state = .idle
                attemptID = nil
                task = nil
            } catch {
                guard attemptID == currentAttemptID else { return }
                state = .failed(error.localizedDescription)
                attemptID = nil
                task = nil
            }
        }
    }

    func cancel(resetState: Bool = true) {
        task?.cancel()
        task = nil
        attemptID = nil
        if resetState { state = .idle }
    }
}

private struct ReferenceScriptEditor: View {
    @Binding var transcript: String
    let audioURL: URL?
    let languageCode: String
    var isDisabled = false

    @State private var recognition = ReferenceScriptRecognitionController()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Text("Reference script")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
                recognitionButton
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $transcript)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .scrollContentBackground(.hidden)
                    .padding(AppTheme.Spacing.xs)
                if transcript.isEmpty {
                    Text("Enter the exact words spoken in the reference audio")
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 72, maxHeight: 120)
            .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            statusView
        }
        .onChange(of: audioURL) { _, _ in recognition.cancel() }
        .onDisappear { recognition.cancel() }
    }

    @ViewBuilder
    private var recognitionButton: some View {
        if recognition.isRecognizing {
            Button {
                recognition.cancel()
            } label: {
                Label("Cancel recognition", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        } else {
            Button {
                recognize()
            } label: {
                Label(transcript.isEmpty ? "Recognize" : "Recognize again", systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(audioURL == nil || isDisabled)
            .help(audioURL == nil ? "Choose or record reference audio first" : "Recognize the spoken script with local ASR")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch recognition.state {
        case .idle:
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(
                    "For higher-fidelity voice cloning, enter the spoken script or click Recognize.",
                    systemImage: "exclamationmark.circle.fill"
                )
                .foregroundStyle(AppTheme.Status.warningColor)
            } else {
                Text("The script is paired with this audio for higher-fidelity voice cloning.")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        case .recognizing(let fraction, let message):
            HStack(spacing: AppTheme.Spacing.smMd) {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text(message)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        case .recognized:
            Label("Recognized locally. Review the script before saving.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Status.successColor)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Status.errorColor)
        }
    }

    private func recognize() {
        guard let audioURL else { return }
        recognition.start(sourceURL: audioURL, languageCode: languageCode) { recognizedText in
            transcript = recognizedText
        }
    }
}

private struct VoiceReferenceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var store = VoiceLibraryStore.shared
    let reference: LocalVoiceReference
    @State private var name: String
    @State private var language: WorkbenchDubLanguage
    @State private var gender: VoiceReferenceGender
    @State private var transcript: String
    @State private var isSaving = false

    init(reference: LocalVoiceReference) {
        self.reference = reference
        _name = State(initialValue: reference.name)
        _language = State(initialValue: WorkbenchDubLanguage(rawValue: reference.languageCode) ?? .english)
        _gender = State(initialValue: reference.gender)
        _transcript = State(initialValue: reference.transcript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Text("Edit reference voice")
                .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
            TextField("Name", text: $name)
            Picker("Language", selection: $language) {
                ForEach(WorkbenchDubLanguage.allCases.filter { $0 != .automatic }) { item in
                    Text(item.label).tag(item)
                }
            }
            Picker("Gender", selection: $gender) {
                ForEach(VoiceReferenceGender.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            ReferenceScriptEditor(
                transcript: $transcript,
                audioURL: store.audioURL(for: reference),
                languageCode: language.rawValue,
                isDisabled: isSaving
            )
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do {
                            try await store.update(
                                id: reference.id,
                                name: name,
                                languageCode: language.rawValue,
                                gender: gender,
                                transcript: transcript
                            )
                            dismiss()
                        } catch {
                            store.errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(width: AppTheme.Workbench.compactPanelWidth)
    }
}

struct VoiceReferencePicker: View {
    @Bindable private var store = VoiceLibraryStore.shared
    @Binding var selection: UUID?
    var languageCode: String
    var defaultLabel = "Model default voice"
    var onManage: (() -> Void)?

    private var options: [LocalVoiceReference] {
        store.compatibleReferences(languageCode: languageCode, including: selection)
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Picker("Reference voice", selection: $selection) {
                Text(defaultLabel).tag(nil as UUID?)
                if !options.isEmpty { Divider() }
                ForEach(options) { reference in
                    Text(reference.isDefault ? "★ \(reference.name)" : reference.name)
                        .tag(reference.id as UUID?)
                }
            }
            .labelsHidden()
            if let selected = store.reference(id: selection) {
                Button {
                    store.togglePlayback(selected)
                } label: {
                    Image(systemName: store.playingID == selected.id ? "stop.fill" : "play.fill")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.borderless)
                .help(store.playingID == selected.id ? "Stop preview" : "Preview voice")
            }
            if let onManage {
                Button(action: onManage) {
                    Image(systemName: "ellipsis")
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                }
                .buttonStyle(.borderless)
                .help("Manage reference voices")
            }
        }
    }
}

struct VoiceReferenceSelectionPanel: View {
    @Bindable private var store = VoiceLibraryStore.shared
    @Binding var selection: UUID?
    var languageCode: String
    var onManage: () -> Void

    private var options: [LocalVoiceReference] {
        store.compatibleReferences(languageCode: languageCode, including: selection)
    }

    private var automaticReference: LocalVoiceReference? {
        store.defaultReference(languageCode: languageCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Session reference voice")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
            Text("Applied unless a speaker or segment has its own voice override.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)

            automaticRow

            if store.isLoading {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    ProgressView().controlSize(.small)
                    Text("Loading saved reference voices…")
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .padding(.vertical, AppTheme.Spacing.sm)
            } else if options.isEmpty {
                Text("No compatible reference voices are saved yet.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.vertical, AppTheme.Spacing.sm)
            } else {
                ForEach(options) { reference in
                    referenceRow(reference)
                }
            }

            Button {
                onManage()
            } label: {
                Label("Add or manage reference voices…", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.borderless)

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var automaticRow: some View {
        voiceRowContainer(isSelected: selection == nil) {
            Button {
                select(nil)
            } label: {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    selectionIndicator(selection == nil)
                    Image(systemName: "waveform")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.lg)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text("Automatic voice")
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        Text(automaticReference.map { "Language default · \($0.name)" } ?? "Qwen model default voice")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let automaticReference {
                previewButton(automaticReference)
            }
        }
    }

    private func referenceRow(_ reference: LocalVoiceReference) -> some View {
        voiceRowContainer(isSelected: selection == reference.id) {
            Button {
                select(reference.id)
            } label: {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    selectionIndicator(selection == reference.id)
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: AppTheme.FontSize.mdLg))
                        .foregroundStyle(AppTheme.Accent.link)
                        .frame(width: AppTheme.IconSize.lg)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(reference.name)
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            if reference.isDefault {
                                Text("DEFAULT")
                                    .font(.system(size: AppTheme.FontSize.xxs, weight: .bold))
                                    .foregroundStyle(AppTheme.Status.successColor)
                            }
                        }
                        Text("\(reference.languageCode.uppercased()) · \(reference.gender.label) · \(reference.duration.formatted(.number.precision(.fractionLength(1))))s")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            previewButton(reference)
        }
    }

    private func voiceRowContainer<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            content()
        }
        .padding(AppTheme.Spacing.smMd)
        .background(
            isSelected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft) : AppTheme.Background.surfaceColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(
                    isSelected ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.thin
                )
        }
    }

    private func selectionIndicator(_ isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            .accessibilityHidden(true)
    }

    private func previewButton(_ reference: LocalVoiceReference) -> some View {
        let isPlaying = store.playingID == reference.id
        return Button {
            store.togglePlayback(reference)
        } label: {
            Label(isPlaying ? "Stop" : "Preview", systemImage: isPlaying ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(isPlaying ? "Stop reference voice preview" : "Preview reference voice")
    }

    private func select(_ id: UUID?) {
        if store.playingID != nil { store.stopPlayback() }
        selection = id
    }
}

private struct VoiceAvatarView: View {
    let URL: URL?
    let fallback: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(fallback.uppercased())
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .frame(width: AppTheme.IconSize.xl * 2, height: AppTheme.IconSize.xl * 2)
        .background(AppTheme.Background.raisedColor, in: Circle())
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(AppTheme.Border.subtleColor) }
        .task(id: URL) {
            guard let URL else {
                image = nil
                return
            }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}
