import AppKit
import SwiftUI

/// Editable cue list aligned with web `TranscriptSegmentsPanel`:
/// inline text edit, split at cursor, merge-down, speaker assign/rename/add, play/seek.
struct SessionSegmentEditor: View {
    let sessionID: UUID
    let contentKey: String
    let scope: WorkbenchStore.SessionCueScope
    let cues: [SubtitleCue]
    let speakerLabels: [String]
    var allowsEditing = true
    let emptyText: String
    let onSeek: (Double) -> Void

    @Bindable private var store = WorkbenchStore.shared
    @State private var editingCueID: Int?
    @State private var editingText = ""
    @State private var cursorOffset: Int?
    @State private var renameTarget: RenameSpeakerTarget?
    @State private var addSpeakerCueID: Int?
    @State private var addSpeakerName = ""
    @State private var autosaveTask: Task<Void, Never>?

    var body: some View {
        if cues.isEmpty {
            ContentUnavailableView(
                "No segments",
                systemImage: "text.alignleft",
                description: Text(emptyText)
            )
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                    SessionCueRow(
                        cue: cue,
                        speakerLabels: speakerLabels,
                        isEditing: allowsEditing && editingCueID == cue.id,
                        editingText: editingBinding(for: cue),
                        cursorOffset: allowsEditing && editingCueID == cue.id
                            ? $cursorOffset
                            : .constant(nil),
                        canSplit: allowsEditing && canSplit,
                        allowsEditing: allowsEditing,
                        onPlay: { onSeek(cue.start) },
                        onBeginEdit: { beginEdit(cue) },
                        onCommitEdit: { commitEditAndClose() },
                        onCancelEdit: { cancelEdit() },
                        onSplit: { splitEditingCue() },
                        onSelectSpeaker: { speaker in
                            store.assignSessionCueSpeaker(
                                sessionID: sessionID,
                                scope: scope,
                                cueID: cue.id,
                                speaker: speaker
                            )
                        },
                        onRenameSpeaker: { label in
                            renameTarget = RenameSpeakerTarget(label: label)
                        },
                        onAddSpeaker: {
                            addSpeakerCueID = cue.id
                            addSpeakerName = ""
                        }
                    )

                    if allowsEditing, index < cues.count - 1 {
                        SessionMergeDivider {
                            store.mergeSessionCueDown(
                                sessionID: sessionID,
                                scope: scope,
                                cueID: cue.id
                            )
                            if editingCueID == cue.id {
                                cancelEdit()
                            }
                        }
                    }
                }
            }
            .alert(
                "Rename speaker",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                if let renameTarget {
                    TextField("Speaker name", text: renameNameBinding(renameTarget.label))
                    Button("Cancel", role: .cancel) { self.renameTarget = nil }
                    Button("Rename") {
                        store.renameSessionSpeaker(
                            sessionID: sessionID,
                            scope: scope,
                            current: renameTarget.label,
                            to: renameTarget.draft
                        )
                        self.renameTarget = nil
                    }
                }
            } message: {
                Text("Updates this label across the selected track.")
            }
            .alert(
                "Add speaker",
                isPresented: Binding(
                    get: { addSpeakerCueID != nil },
                    set: { if !$0 { addSpeakerCueID = nil } }
                )
            ) {
                TextField("Speaker name", text: $addSpeakerName)
                Button("Cancel", role: .cancel) { addSpeakerCueID = nil }
                Button("Add") {
                    if let cueID = addSpeakerCueID {
                        store.addSessionCueSpeaker(
                            sessionID: sessionID,
                            scope: scope,
                            cueID: cueID,
                            speaker: addSpeakerName
                        )
                    }
                    addSpeakerCueID = nil
                }
            } message: {
                Text("Assign a new speaker label to this segment.")
            }
            .onChange(of: contentKey) { _, _ in
                resetEditingState()
            }
        }
    }

    private func resetEditingState() {
        autosaveTask?.cancel()
        editingCueID = nil
        editingText = ""
        cursorOffset = nil
    }

    private var canSplit: Bool {
        guard let offset = cursorOffset, editingCueID != nil else { return false }
        let length = (editingText as NSString).length
        return offset > 0 && offset < length
    }

    private func editingBinding(for cue: SubtitleCue) -> Binding<String> {
        Binding(
            get: { editingCueID == cue.id ? editingText : cue.text },
            set: { value in
                guard editingCueID == cue.id else { return }
                editingText = value
                scheduleAutosave()
            }
        )
    }

    private func renameNameBinding(_ label: String) -> Binding<String> {
        Binding(
            get: { renameTarget?.draft ?? label },
            set: { value in
                renameTarget = RenameSpeakerTarget(label: label, draft: value)
            }
        )
    }

    private func beginEdit(_ cue: SubtitleCue) {
        guard allowsEditing else { return }
        autosaveTask?.cancel()
        editingCueID = cue.id
        editingText = cue.text
        cursorOffset = nil
    }

    private func cancelEdit() {
        autosaveTask?.cancel()
        editingCueID = nil
        editingText = ""
        cursorOffset = nil
    }

    private func commitEditAndClose() {
        guard let cueID = editingCueID else { return }
        autosaveTask?.cancel()
        store.updateSessionCueText(
            sessionID: sessionID,
            scope: scope,
            cueID: cueID,
            text: editingText
        )
        cancelEdit()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard let cueID = editingCueID else { return }
        let text = editingText
        let sessionID = sessionID
        let scope = scope
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, editingCueID == cueID else { return }
            store.updateSessionCueText(
                sessionID: sessionID,
                scope: scope,
                cueID: cueID,
                text: text
            )
        }
    }

    private func splitEditingCue() {
        guard let cueID = editingCueID,
              let offset = cursorOffset
        else { return }
        let nsText = editingText as NSString
        guard offset > 0, offset < nsText.length else { return }
        let left = nsText.substring(to: offset)
        let right = nsText.substring(from: offset)
        autosaveTask?.cancel()
        store.splitSessionCue(
            sessionID: sessionID,
            scope: scope,
            cueID: cueID,
            leftText: left,
            rightText: right
        )
        cancelEdit()
    }
}

extension WorkbenchStore.SessionCueScope {
    var contentKey: String {
        switch self {
        case .transcript:
            return "transcript"
        case .source:
            return "source"
        case .translation(let languageCode):
            return "translation-\(languageCode.lowercased())"
        case .dub:
            return "dub"
        }
    }
}

private struct RenameSpeakerTarget: Identifiable {
    let label: String
    var draft: String
    var id: String { label }

    init(label: String, draft: String? = nil) {
        self.label = label
        self.draft = draft ?? label
    }
}

private struct SessionMergeDivider: View {
    let onMerge: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isHovered ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : Color.clear)
                .frame(height: AppTheme.BorderWidth.hairline)
                .padding(.horizontal, AppTheme.Spacing.xl)

            Button(action: onMerge) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .background(
                        Circle().fill(AppTheme.Background.surfaceColor)
                    )
                    .overlay {
                        Circle().strokeBorder(
                            isHovered ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                    }
                    .foregroundStyle(isHovered ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                    .opacity(isHovered ? AppTheme.Opacity.prominent : AppTheme.Opacity.subtle)
                    .scaleEffect(isHovered ? 1 : 0.85)
            }
            .buttonStyle(.plain)
            .help("Merge with segment below")
        }
        .frame(height: AppTheme.Spacing.lg)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}

private struct SessionCueRow: View {
    let cue: SubtitleCue
    let speakerLabels: [String]
    let isEditing: Bool
    @Binding var editingText: String
    @Binding var cursorOffset: Int?
    let canSplit: Bool
    var allowsEditing = true
    let onPlay: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onSplit: () -> Void
    let onSelectSpeaker: (String) -> Void
    let onRenameSpeaker: (String) -> Void
    let onAddSpeaker: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Accent.link)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Play from this segment")

            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("\(Self.formatTime(cue.start)) — \(Self.formatTime(cue.end))")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)

                    if allowsEditing {
                        speakerMenu
                    } else if let speaker = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !speaker.isEmpty {
                        Text(speaker)
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }

                    Spacer(minLength: 0)

                    if allowsEditing, isHovered || isEditing {
                        Button(action: onBeginEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Edit text")
                    }
                }

                ZStack(alignment: .topLeading) {
                    if isEditing {
                        SessionCueTextEditor(
                            text: $editingText,
                            cursorOffset: $cursorOffset,
                            onCommit: onCommitEdit,
                            onCancel: onCancelEdit
                        )
                        .frame(minHeight: AppTheme.FontSize.mdLg * 2.4)

                        if canSplit {
                            Button(action: onSplit) {
                                Image(systemName: "scissors")
                                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                                    .padding(AppTheme.Spacing.xs)
                                    .background(
                                        AppTheme.Background.raisedColor,
                                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("Split at cursor")
                            .padding(.top, AppTheme.Spacing.xxs)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    } else {
                        Text(cue.text)
                            .font(.system(size: AppTheme.FontSize.mdLg))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard allowsEditing else { return }
                                onBeginEdit()
                            }
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(minHeight: AppTheme.Workbench.transcriptCardMinHeight, alignment: .topLeading)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(
                    isEditing ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted) : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.thin
                )
        }
        .onHover { isHovered = $0 }
    }

    private var speakerMenu: some View {
        Menu {
            ForEach(speakerLabels, id: \.self) { label in
                Button {
                    onSelectSpeaker(label)
                } label: {
                    if cue.speaker == label {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
            if !speakerLabels.isEmpty {
                Divider()
            }
            Button("Add speaker…", action: onAddSpeaker)
            if let speaker = cue.speaker, !speaker.isEmpty {
                Button("Rename \(speaker)…") {
                    onRenameSpeaker(speaker)
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text({
                    let trimmed = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? "Speaker" : trimmed
                }())
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            }
            .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .menuStyle(.borderlessButton)
        .help("Assign speaker")
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = total - Double(minutes * 60)
        if minutes > 0 {
            return String(format: "%d:%04.1f", minutes, secs)
        }
        return String(format: "%.1fs", secs)
    }
}

private struct SessionCueTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int?
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: AppTheme.FontSize.mdLg)
        textView.textColor = NSColor(AppTheme.Text.primaryColor)
        textView.insertionPointColor = NSColor(AppTheme.Text.primaryColor)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: AppTheme.Spacing.xxs)
        textView.string = text
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Preserve the native input composition while SwiftUI re-renders.
        guard textView.window?.firstResponder !== textView else { return }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selected.location, text.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SessionCueTextEditor
        weak var textView: NSTextView?
        private var isCancelling = false

        init(parent: SessionCueTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.cursorOffset = textView.selectedRange().location
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.cursorOffset = textView.selectedRange().location
        }

        func textDidEndEditing(_ notification: Notification) {
            if isCancelling {
                isCancelling = false
                return
            }
            parent.onCommit()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                isCancelling = true
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}
