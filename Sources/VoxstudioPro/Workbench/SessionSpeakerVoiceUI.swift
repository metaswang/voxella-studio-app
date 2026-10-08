import SwiftUI

/// Voice-library actions available to speaker menus inside one session.
struct SessionSpeakerVoiceContext {
    let sessionID: UUID
    let onSaveVoice: (String) -> Void
}

extension EnvironmentValues {
    @Entry var sessionSpeakerVoiceContext: SessionSpeakerVoiceContext? = nil
}

/// Menu section that links a session speaker to a library person or saves its
/// voice as a new reference.
struct SessionSpeakerVoiceMenuSection: View {
    let speaker: String
    let context: SessionSpeakerVoiceContext
    @Bindable private var people = SpeakerPersonStore.shared
    @Bindable private var store = WorkbenchStore.shared

    private var identity: SessionSpeakerIdentity? {
        store.speakerIdentity(sessionID: context.sessionID, label: speaker)
    }

    var body: some View {
        Divider()
        Menu(L10n.string("Link to person")) {
            ForEach(people.sortedPersons) { person in
                Button {
                    store.linkSessionSpeaker(sessionID: context.sessionID, label: speaker, personID: person.id)
                } label: {
                    if identity?.personID == person.id {
                        Label(person.name, systemImage: "checkmark")
                    } else {
                        Text(person.name)
                    }
                }
            }
            if identity?.personID != nil {
                Divider()
                Button(L10n.string("Unlink person")) {
                    store.linkSessionSpeaker(sessionID: context.sessionID, label: speaker, personID: nil)
                }
            }
        }
        .disabled(people.persons.isEmpty)
        Button(L10n.string("Save voice to library…")) { context.onSaveVoice(speaker) }
    }
}

/// Small glyph beside a speaker label describing its identity status.
struct SessionSpeakerIdentityGlyph: View {
    let speaker: String?
    @Environment(\.sessionSpeakerVoiceContext) private var context
    @Bindable private var store = WorkbenchStore.shared

    var body: some View {
        if let speaker, let context,
           let identity = store.speakerIdentity(sessionID: context.sessionID, label: speaker),
           let style = Self.style(for: identity) {
            Image(systemName: style.image)
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .foregroundStyle(style.color)
                .help(L10n.string(style.help))
                .accessibilityLabel(L10n.string(style.help))
        }
    }

    private static func style(for identity: SessionSpeakerIdentity) -> (image: String, color: Color, help: String)? {
        switch identity.status {
        case .matched: ("person.fill.checkmark", AppTheme.Status.successColor, "Recognized from the voice library")
        case .manual where identity.personID != nil: ("person.fill", AppTheme.Text.tertiaryColor, "Linked to a voice library person")
        case .needsReview: ("exclamationmark.triangle.fill", AppTheme.Status.warningColor, "This speaker may contain more than one voice")
        case .ambiguous, .conflict: ("questionmark.circle", AppTheme.Status.warningColor, "Close to more than one person; kept anonymous")
        default: nil
        }
    }
}

struct SessionSpeakerVoiceTarget: Identifiable {
    let label: String
    var id: String { label }
}

/// Saves a session speaker's clear speech as a reference voice and links it to
/// a person, extracting the voiceprint automatically.
struct SessionSpeakerVoiceSheet: View {
    let sessionID: UUID
    let label: String
    @Environment(\.dismiss) private var dismiss
    @Bindable private var people = SpeakerPersonStore.shared
    @Bindable private var store = WorkbenchStore.shared
    @State private var useExisting = false
    @State private var personName = ""
    @State private var existingPersonID: UUID?
    @State private var gender: VoiceReferenceGender = .female
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var availableSpeech: Double { store.cleanSpeechDuration(sessionID: sessionID, label: label) }
    private var hasEnoughSpeech: Bool { availableSpeech >= SpeakerVoiceprintPolicy.minimumEnrollmentDuration }
    private var canSave: Bool {
        hasEnoughSpeech && !isSaving
            && (useExisting ? existingPersonID != nil : !personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Save voice to library"))
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text(L10n.format(
                    "Creates a reference voice from %@'s clear speech in this session and prepares a voiceprint for recognizing them later.",
                    label
                ))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            }

            speechMeter

            if !people.persons.isEmpty {
                Picker("", selection: $useExisting) {
                    Text(L10n.string("New person")).tag(false)
                    Text(L10n.string("Existing person")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if useExisting {
                Picker(L10n.string("Person"), selection: $existingPersonID) {
                    Text(L10n.string("Choose a person")).tag(UUID?.none)
                    ForEach(people.sortedPersons) { person in
                        Text(person.name).tag(Optional(person.id))
                    }
                }
            } else {
                TextField(L10n.string("Person name"), text: $personName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }

            Picker(L10n.string("Voice type"), selection: $gender) {
                ForEach(VoiceReferenceGender.allCases) { item in
                    Text(L10n.string(key: item.label)).tag(item)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("Saving voice…"))
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                Button(L10n.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Save to library"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(AppTheme.Spacing.xlXxl)
        .frame(width: AppTheme.zoomed(400))
        .onAppear(perform: prefill)
    }

    private var speechMeter: some View {
        let recommended = SpeakerVoiceprintPolicy.recommendedEnrollmentDuration
        let fraction = min(1, availableSpeech / recommended.lowerBound)
        let color: Color = !hasEnoughSpeech ? AppTheme.Status.errorColor
            : availableSpeech < recommended.lowerBound ? AppTheme.Status.warningColor : AppTheme.Status.successColor
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text(L10n.string("Clear speech"))
                Spacer()
                Text(L10n.format("%@ s", availableSpeech.formatted(.number.precision(.fractionLength(1)))))
                    .monospacedDigit()
            }
            .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
            ProgressView(value: fraction).tint(color)
            Text(L10n.string(!hasEnoughSpeech
                ? "At least 3 seconds of this speaker talking alone is needed."
                : availableSpeech < recommended.lowerBound
                    ? "Enough to start. 15–30 seconds gives more reliable recognition."
                    : "Plenty of clear speech for a reliable voiceprint."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private func prefill() {
        let identity = store.speakerIdentity(sessionID: sessionID, label: label)
        if let personID = identity?.personID, people.person(id: personID) != nil {
            useExisting = true
            existingPersonID = personID
        } else if let match = people.person(named: label) {
            useExisting = true
            existingPersonID = match.id
        } else {
            personName = Self.isAnonymous(label) ? "" : label
        }
    }

    static func isAnonymous(_ label: String) -> Bool {
        label.range(of: #"^Speaker\s*\d+$"#, options: .regularExpression) != nil
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.saveSessionSpeakerToLibrary(
                    sessionID: sessionID,
                    label: label,
                    personName: personName,
                    existingPersonID: useExisting ? existingPersonID : nil,
                    gender: gender
                )
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Session-level people recognition: candidates, results and re-matching.
/// Only identity is recomputed; diarization and text stay as they are.
struct SessionSpeakerIdentityPanel: View {
    let job: WorkbenchTranscriptionJob
    @Bindable private var store = WorkbenchStore.shared
    @Bindable private var activity = SpeakerIdentityActivity.shared
    @Bindable private var people = SpeakerPersonStore.shared

    private var candidates: Binding<[UUID]> {
        Binding(
            get: { job.candidatePersonIDs },
            set: { store.setCandidatePersons($0, sessionID: job.id) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            SpeakerCandidatePicker(selection: candidates)
            Spacer(minLength: AppTheme.Spacing.md)
            VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                if let phase = activity.phase(for: job.id) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(L10n.string(Self.label(for: phase)))
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                } else if !job.candidatePersonIDs.isEmpty {
                    Button(L10n.string("Match again")) { store.rematchSessionSpeakers(sessionID: job.id) }
                        .buttonStyle(.borderless)
                }
                if let summary {
                    Text(summary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .multilineTextAlignment(.trailing)
                }
                if let error = job.speakerIdentities?.lastMatchError {
                    Text(L10n.display(error))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private var summary: String? {
        guard let entries = job.speakerIdentities?.entries, !entries.isEmpty else { return nil }
        let named = entries.filter { $0.personID != nil }.count
        return L10n.format("%@ of %@ speakers named", named, entries.count)
    }

    private static func label(for phase: SpeakerIdentityActivity.Phase) -> String {
        switch phase {
        case .preparing: "Preparing voiceprints…"
        case .matching: "Matching speakers…"
        case .savingVoice: "Saving voice…"
        }
    }
}
