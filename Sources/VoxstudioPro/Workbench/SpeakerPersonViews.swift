import SwiftUI

// MARK: - Status

extension SpeakerPerson.VoiceprintState {
    var label: String {
        switch self {
        case .notPrepared: "Voiceprint not prepared"
        case .preparing: "Preparing voiceprint…"
        case .ready: "Voiceprint ready"
        case .needsReview: "Needs review"
        case .insufficientAudio: "Needs more speech"
        case .needsSamples: "Needs new samples"
        case .failed: "Voiceprint failed"
        }
    }

    var systemImage: String {
        switch self {
        case .notPrepared: "waveform.badge.plus"
        case .preparing: "waveform"
        case .ready: "checkmark.seal.fill"
        case .needsReview: "exclamationmark.triangle.fill"
        case .insufficientAudio, .needsSamples: "waveform.badge.exclamationmark"
        case .failed: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: AppTheme.Status.successColor
        case .needsReview, .insufficientAudio, .needsSamples: AppTheme.Status.warningColor
        case .failed: AppTheme.Status.errorColor
        case .notPrepared, .preparing: AppTheme.Text.tertiaryColor
        }
    }
}

struct SpeakerVoiceprintBadge: View {
    let person: SpeakerPerson

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if person.voiceprintState == .preparing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: person.voiceprintState.systemImage)
            }
            Text(L10n.string(person.voiceprintState.label))
        }
        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(person.voiceprintState.color)
        .help(L10n.string(Self.help(for: person)))
    }

    static func help(for person: SpeakerPerson) -> String {
        switch person.voiceprintState {
        case .needsReview: "Some samples sound like a different person. Check this person's reference voices."
        case .insufficientAudio: "Add at least 3 seconds of clear single-speaker speech; 15–30 seconds works best."
        case .needsSamples: "The voiceprint model was updated and the original audio is gone. Add a new reference voice."
        case .failed: person.voiceprintMessage ?? "Try preparing the voiceprint again."
        default: "Used to recognize this person in transcripts."
        }
    }
}

// MARK: - Task candidates

/// Multi-select of library people a task should recognize. Empty by default.
struct SpeakerCandidatePicker: View {
    @Binding var selection: [UUID]
    @Bindable private var people = SpeakerPersonStore.shared
    @State private var isPresented = false

    private var summary: String {
        switch selection.count {
        case 0: L10n.string("Keep speakers anonymous")
        case 1: people.person(id: selection.first)?.name ?? L10n.string("1 person")
        default: L10n.format("%@ people", selection.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Recognize people"))
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            Button { isPresented.toggle() } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: selection.isEmpty ? "person.crop.circle.badge.questionmark" : "person.2.fill")
                    Text(summary).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .font(.system(size: AppTheme.FontSize.sm))
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { list }
            Text(L10n.string("Speakers are named only when they clearly match someone you choose; everyone else stays anonymous."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { selection.removeAll { people.person(id: $0) == nil && !people.isLoading } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.string("People to recognize"))
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                Spacer()
                if !selection.isEmpty {
                    Button(L10n.string("Clear")) { selection = [] }
                        .buttonStyle(.borderless)
                }
            }
            .padding(AppTheme.Spacing.lg)
            Divider()
            if people.persons.isEmpty {
                Text(L10n.string("Add people in the Voice library to name speakers automatically."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(AppTheme.Spacing.lg)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(people.sortedPersons) { person in
                            Toggle(isOn: binding(for: person.id)) {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text(person.name)
                                        .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                                    SpeakerVoiceprintBadge(person: person)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, AppTheme.Spacing.xs)
                        }
                    }
                    .padding(AppTheme.Spacing.lg)
                }
                .frame(maxHeight: AppTheme.zoomed(280))
            }
        }
        .frame(width: AppTheme.zoomed(300))
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { if !selection.contains(id) { selection.append(id) } }
                else { selection.removeAll { $0 == id } }
            }
        )
    }
}

// MARK: - Voice library people

struct SpeakerPeopleSection: View {
    @Bindable private var people = SpeakerPersonStore.shared
    @Bindable private var library = VoiceLibraryStore.shared
    @State private var newPersonName = ""
    @State private var isAdding = false
    @State private var renaming: SpeakerPerson?
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("People")
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    Text("Group reference voices by person to recognize them in transcripts across projects.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { isAdding.toggle() }
                } label: {
                    Label(L10n.string(isAdding ? "Cancel" : "New person"), systemImage: isAdding ? "xmark" : "person.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(AppTheme.Spacing.lgXl)

            if isAdding {
                HStack(spacing: AppTheme.Spacing.md) {
                    TextField(L10n.string("Person name"), text: $newPersonName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addPerson)
                    Button(L10n.string("Add"), action: addPerson)
                        .buttonStyle(.borderedProminent)
                        .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding([.horizontal, .bottom], AppTheme.Spacing.lgXl)
                .transition(.opacity)
            }

            Divider()

            VStack(spacing: AppTheme.Spacing.mdLg) {
                if people.persons.isEmpty {
                    ContentUnavailableView(
                        L10n.string("No people yet"),
                        systemImage: "person.2.badge.plus",
                        description: Text(L10n.string("Create a person, then link one or more reference voices. Voices from different languages and microphones can belong to the same person."))
                    )
                    .frame(minHeight: AppTheme.Workbench.voiceRowMinHeight * 2)
                } else {
                    ForEach(people.sortedPersons) { person in personRow(person) }
                }
            }
            .padding(AppTheme.Spacing.lgXl)
        }
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .alert(
            L10n.string("Rename person"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(L10n.string("Person name"), text: $renameDraft)
            Button(L10n.string("Cancel"), role: .cancel) { renaming = nil }
            Button(L10n.string("Rename")) {
                if let renaming { people.rename(renaming.id, to: renameDraft) }
                renaming = nil
            }
        }
    }

    private func personRow(_ person: SpeakerPerson) -> some View {
        let references = person.referenceIDs.compactMap { library.reference(id: $0) }
        return HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: AppTheme.IconSize.lg))
                .foregroundStyle(AppTheme.Accent.primary.opacity(0.85))
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(person.name)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                SpeakerVoiceprintBadge(person: person)
                Text(detail(person, references: references))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                if !references.isEmpty {
                    Text(references.map(\.name).joined(separator: " · "))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Menu(L10n.string("Link reference voice")) {
                    ForEach(library.references) { reference in
                        Button {
                            people.link(reference: reference.id, to: person.referenceIDs.contains(reference.id) ? nil : person.id)
                        } label: {
                            if person.referenceIDs.contains(reference.id) {
                                Label(reference.name, systemImage: "checkmark")
                            } else {
                                Text(reference.name)
                            }
                        }
                    }
                }
                .disabled(library.references.isEmpty)
                Button(L10n.string("Re-extract voiceprint")) { people.prepareVoiceprint(person.id, force: true) }
                    .disabled(person.referenceIDs.isEmpty || people.isPreparing(person.id))
                Button(L10n.string("Rename…")) {
                    renameDraft = person.name
                    renaming = person
                }
                Divider()
                Button(L10n.string("Delete person"), role: .destructive) { people.deletePerson(person.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(AppTheme.Spacing.lgXl)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func detail(_ person: SpeakerPerson, references: [LocalVoiceReference]) -> String {
        let speech = person.voiceprint?.effectiveDuration ?? 0
        return L10n.format(
            "%@ reference voices · %@ s clear speech",
            references.count,
            speech.formatted(.number.precision(.fractionLength(0)))
        )
    }

    private func addPerson() {
        let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        people.createPerson(name: name)
        newPersonName = ""
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { isAdding = false }
    }
}

/// Person assignment for one reference voice row.
struct ReferencePersonMenu: View {
    let reference: LocalVoiceReference
    @Bindable private var people = SpeakerPersonStore.shared

    var body: some View {
        Menu(L10n.string("Person")) {
            Button {
                people.link(reference: reference.id, to: nil)
            } label: {
                if people.person(forReference: reference.id) == nil {
                    Label(L10n.string("Not linked"), systemImage: "checkmark")
                } else {
                    Text(L10n.string("Not linked"))
                }
            }
            if !people.persons.isEmpty { Divider() }
            ForEach(people.sortedPersons) { person in
                Button {
                    people.link(reference: reference.id, to: person.id)
                } label: {
                    if person.referenceIDs.contains(reference.id) {
                        Label(person.name, systemImage: "checkmark")
                    } else {
                        Text(person.name)
                    }
                }
            }
            Divider()
            Button(L10n.format("New person “%@”", reference.name)) {
                people.createPerson(name: reference.name, referenceIDs: [reference.id])
            }
        }
    }
}
