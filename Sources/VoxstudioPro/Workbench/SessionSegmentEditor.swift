import AppKit
import SwiftUI

/// Editable cue list aligned with web `TranscriptSegmentsPanel`:
/// inline text edit, split at cursor, merge-down, speaker assign/rename/add, play/seek.
struct SessionSegmentEditor: View {
    let sessionID: UUID
    let contentKey: String
    let scope: WorkbenchStore.SessionCueScope
    let cues: [SubtitleCue]
    let activeCueID: Int?
    let speakerLabels: [String]
    var speakerDisplayNames: [String: String] = [:]
    var allowsEditing = true
    var showsSubtitleDisplayText = false
    var aggregatesSpeakers = false
    @Binding var expandedParagraphID: Int?
    let emptyText: String
    let onSeek: (Double, Double) -> Void

    @Bindable private var store = WorkbenchStore.shared
    @State private var editingCueID: Int?
    @State private var editingText = ""
    @State private var cursorOffset: Int?
    @State private var renameTarget: RenameSpeakerTarget?
    @State private var addSpeakerCueIDs: [Int]?
    @State private var addSpeakerName = ""
    @State private var colorTarget: RenameSpeakerTarget?
    @State private var autosaveTask: Task<Void, Never>?

    var body: some View {
        if cues.isEmpty {
            ContentUnavailableView(
                L10n.string("No segments"),
                systemImage: "text.alignleft",
                description: Text(L10n.display(emptyText))
            )
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
        } else {
            LazyVStack(alignment: .leading, spacing: showsSubtitleDisplayText ? 0 : AppTheme.Spacing.lg) {
                ForEach(displayRows) { row in
                    switch row {
                    case .paragraph(let paragraph):
                        cueRow(paragraph.cues[0], paragraph: paragraph).id(row.id)
                    case .cue(let cue):
                        cueRow(cue).id(row.id)
                    case .divider(let cueID):
                        SessionMergeDivider {
                            store.mergeSessionCueDown(sessionID: sessionID, scope: scope, cueID: cueID)
                            if editingCueID == cueID { cancelEdit() }
                        }
                    case .done:
                        Button(L10n.string("Done")) {
                            commitEditAndClose()
                            expandedParagraphID = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .padding(.leading, AppTheme.Spacing.xl)
                    }
                }
            }
            // Transcript paragraphs and subtitle rows reuse cue IDs but have
            // different heights. Discard the lazy layout cache when switching
            // tracks, languages or presentation modes.
            .id(contentKey)
            .padding(.vertical, AppTheme.Spacing.lg)
            .onAppear { store.ensureSessionSpeakerColors(sessionID: sessionID, labels: speakerLabels) }
            .onChange(of: speakerLabels) { _, labels in
                store.ensureSessionSpeakerColors(sessionID: sessionID, labels: labels)
            }
            .popover(item: $colorTarget) { target in
                SessionSpeakerColorPicker(label: target.label, selection: Binding(
                    get: { colors.values[target.label] ?? SessionSpeakerColor.presets[0] },
                    set: { store.setSessionSpeakerColor(sessionID: sessionID, speaker: target.label, color: $0) }
                ))
            }
            .alert(
                L10n.string("Rename speaker"),
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                if let renameTarget {
                    TextField(L10n.string("Speaker name"), text: renameNameBinding(renameTarget.label))
                    Button(L10n.string("Cancel"), role: .cancel) { self.renameTarget = nil }
                    Button(L10n.string("Rename")) {
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
                Text(L10n.string("Updates this label across the selected track."))
            }
            .alert(
                L10n.string("Add speaker"),
                isPresented: Binding(
                    get: { addSpeakerCueIDs != nil },
                    set: { if !$0 { addSpeakerCueIDs = nil } }
                )
            ) {
                TextField(L10n.string("Speaker name"), text: $addSpeakerName)
                Button(L10n.string("Cancel"), role: .cancel) { addSpeakerCueIDs = nil }
                Button(L10n.string("Add")) {
                    if let cueIDs = addSpeakerCueIDs {
                        store.assignSessionCuesSpeaker(
                            sessionID: sessionID,
                            scope: scope,
                            cueIDs: cueIDs,
                            speaker: addSpeakerName
                        )
                    }
                    addSpeakerCueIDs = nil
                }
            } message: {
                Text(L10n.string("Assign a new speaker label to this segment."))
            }
            .onChange(of: contentKey) { _, _ in
                resetEditingState()
            }
        }
    }

    private var displayRows: [SessionTranscriptDisplayRow] {
        SessionTranscriptDisplayRow.rows(cues, aggregate: aggregatesSpeakers, expandedID: expandedParagraphID, allowsEditing: allowsEditing)
    }

    private var colors: SessionSpeakerColors {
        store.sessionSpeakerColors(sessionID: sessionID, labels: speakerLabels)
    }

    private func cueRow(_ cue: SubtitleCue, paragraph: SessionTranscriptParagraph? = nil) -> some View {
        let members = paragraph?.cues ?? [cue]
        return SessionCueRow(
            cue: cue,
            isActive: members.contains { $0.id == activeCueID },
            speakerLabels: speakerLabels,
            isEditing: allowsEditing && editingCueID == cue.id,
            editingText: editingBinding(for: cue),
            cursorOffset: allowsEditing && editingCueID == cue.id ? $cursorOffset : .constant(nil),
            canSplit: allowsEditing && canSplit,
            allowsEditing: allowsEditing,
            showsSubtitleDisplayText: showsSubtitleDisplayText,
            onPlay: {
                let target = members.first { $0.id == activeCueID } ?? cue
                onSeek(target.start, paragraph?.end ?? target.end)
            },
            onBeginEdit: {
                if let paragraph { expandedParagraphID = paragraph.id }
                beginEdit(cue)
            },
            onCommitEdit: { commitEditAndClose() },
            onCancelEdit: { cancelEdit() },
            onSplit: { splitEditingCue() },
            onSelectSpeaker: { speaker in
                store.assignSessionCuesSpeaker(sessionID: sessionID, scope: scope, cueIDs: members.map(\.id), speaker: speaker)
            },
            onRenameSpeaker: { renameTarget = RenameSpeakerTarget(label: $0) },
            onAddSpeaker: { addSpeakerCueIDs = members.map(\.id); addSpeakerName = "" },
            speakerColor: colors.values[cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""]?.labelColor ?? AppTheme.Text.secondaryColor,
            displayCues: paragraph?.cues ?? [],
            activeDisplayCueID: activeCueID,
            onChangeSpeakerColor: { colorTarget = RenameSpeakerTarget(label: $0) },
            onBeginEditCue: { id in
                if let paragraph { expandedParagraphID = paragraph.id }
                if let member = members.first(where: { $0.id == id }) { beginEdit(member) }
            },
            speakerDisplayNames: speakerDisplayNames
        )
    }

    private func resetEditingState() {
        autosaveTask?.cancel()
        expandedParagraphID = nil
        colorTarget = nil
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
            .help(L10n.string("Merge with segment below"))
        }
        .frame(height: AppTheme.Spacing.md)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}

struct SessionCueRow: View {
    let cue: SubtitleCue
    let isActive: Bool
    let speakerLabels: [String]
    let isEditing: Bool
    @Binding var editingText: String
    @Binding var cursorOffset: Int?
    let canSplit: Bool
    var allowsEditing = true
    var showsSubtitleDisplayText = false
    let onPlay: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onSplit: () -> Void
    let onSelectSpeaker: (String) -> Void
    let onRenameSpeaker: (String) -> Void
    let onAddSpeaker: () -> Void
    var speakerColor: Color = AppTheme.Text.secondaryColor
    var displayCues: [SubtitleCue] = []
    var activeDisplayCueID: Int?
    var onChangeSpeakerColor: (String) -> Void = { _ in }
    var onBeginEditCue: (Int) -> Void = { _ in }
    var speakerDisplayNames: [String: String] = [:]

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            Button(action: onPlay) {
                Image(systemName: isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(isActive ? speakerColor : AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .background(AppTheme.Background.raisedColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(isActive ? "Pause" : "Play from this segment"))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if allowsEditing {
                        speakerMenu
                    } else if let speaker = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !speaker.isEmpty {
                        Text(displayName(speaker))
                            .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                            .foregroundStyle(speakerColor)
                    }

                    Spacer(minLength: 0)

                    Text("\(Self.formatTime(displayCues.map(\.start).min() ?? cue.start)) — \(Self.formatTime(displayCues.map(\.end).max() ?? cue.end))")
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)

                    if allowsEditing, isHovered || isEditing {
                        Button(action: onBeginEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Edit text"))
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
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // Let sizeThatFits measure the proposed column width in the
                        // same layout pass. A separate frame based on a geometry
                        // preference can stay at its initial one-line height.
                        .fixedSize(horizontal: false, vertical: true)

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
                            .help(L10n.string("Split at cursor"))
                            .padding(.top, AppTheme.Spacing.xxs)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    } else if !displayCues.isEmpty {
                        Text(paragraphText)
                            .font(.system(size: AppTheme.FontSize.mdLg))
                            .lineSpacing(AppTheme.Spacing.xs)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                guard allowsEditing, url.scheme == "voxstudio-cue",
                                      let id = Int(url.path) else { return .discarded }
                                onBeginEditCue(id)
                                return .handled
                            })
                    } else {
                        Text(showsSubtitleDisplayText ? TranscriptSegmenter.renderedSubtitleText(cue.text) : cue.text)
                            .font(.system(size: AppTheme.FontSize.mdLg))
                            .lineSpacing(AppTheme.Spacing.xs)
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, showsSubtitleDisplayText ? AppTheme.Spacing.sm : AppTheme.Spacing.lgXl)
        .frame(minHeight: showsSubtitleDisplayText ? 0 : AppTheme.Workbench.transcriptCardMinHeight, alignment: .topLeading)
        .background(isEditing ? AppTheme.Background.raisedColor : Color.clear, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .onHover { isHovered = $0 }
    }

    private var paragraphText: AttributedString {
        var result = AttributedString()
        for (index, item) in displayCues.enumerated() {
            if index > 0 {
                result.append(AttributedString(SessionTranscriptParagraph.separator(displayCues[index - 1].text, item.text)))
            }
            var text = AttributedString(item.text)
            text.foregroundColor = AppTheme.Text.primaryColor
            if allowsEditing { text.link = URL(string: "voxstudio-cue:\(item.id)") }
            if item.id == activeDisplayCueID { text.backgroundColor = speakerColor.opacity(AppTheme.Opacity.soft) }
            result.append(text)
        }
        return result
    }

    private var speakerMenu: some View {
        Menu {
            ForEach(speakerLabels, id: \.self) { label in
                Button {
                    onSelectSpeaker(label)
                } label: {
                    if cue.speaker == label {
                        Label(displayName(label), systemImage: "checkmark")
                    } else {
                        Text(displayName(label))
                    }
                }
            }
            if !speakerLabels.isEmpty {
                Divider()
            }
            Button(L10n.string("Add speaker…"), action: onAddSpeaker)
            if let speaker = cue.speaker, !speaker.isEmpty {
                Button(L10n.format("Rename %@…", displayName(speaker))) {
                    onRenameSpeaker(speaker)
                }
                Button(L10n.string("Change color…")) { onChangeSpeakerColor(speaker) }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text({
                    let trimmed = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? L10n.string("Speaker") : displayName(trimmed)
                }())
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                    .foregroundColor(speakerColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            }
            .foregroundStyle(speakerColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(speakerColor)
        .help(L10n.string("Assign speaker"))
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

    private func displayName(_ key: String) -> String {
        let name = speakerDisplayNames[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? key : name
    }
}

private enum SessionCueEditorMetrics {
    static var font: NSFont { .systemFont(ofSize: AppTheme.FontSize.mdLg) }
    static var verticalInset: CGFloat { AppTheme.Spacing.xxs }
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = AppTheme.Spacing.xs
        return style
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let font = font
        let inset = verticalInset
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let minHeight = lineHeight + inset * 2
        guard width > 1 else { return minHeight }

        let sample = text.isEmpty ? " " : text
        let storage = NSTextStorage(string: sample, attributes: [.font: font, .paragraphStyle: paragraphStyle])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        // A trailing newline leaves the caret on an extra empty line, which
        // usedRect alone omits.
        let contentHeight = manager.extraLineFragmentTextContainer === container
            ? max(used.maxY, manager.extraLineFragmentRect.maxY)
            : used.maxY
        return max(minHeight, ceil(contentHeight + inset * 2))
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = resolvedWidth(proposal: proposal, nsView: nsView)
        return CGSize(
            width: width > 1 ? width : (proposal.width ?? 0),
            height: SessionCueEditorMetrics.height(for: text, width: width)
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let textView = NSTextView()
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = SessionCueEditorMetrics.font
        textView.defaultParagraphStyle = SessionCueEditorMetrics.paragraphStyle
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
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 0, height: SessionCueEditorMetrics.verticalInset)
        textView.string = text
        scrollView.documentView = textView
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
        let isFirstResponder = textView.window?.firstResponder === textView
        if !isFirstResponder, textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selected.location, text.utf16.count),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }
        let width = scrollView.bounds.width
        if width > 1, let textContainer = textView.textContainer,
           abs(textContainer.containerSize.width - width) > 0.5 {
            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.frame.size.width = width
        }
    }

    private func resolvedWidth(proposal: ProposedViewSize, nsView: NSScrollView) -> CGFloat {
        if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
            return proposed
        }
        if nsView.bounds.width > 1 {
            return nsView.bounds.width
        }
        return 0
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
