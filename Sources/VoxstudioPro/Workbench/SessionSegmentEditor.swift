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
    var highlightSubtitleCues: [SubtitleCue] = []
    var activeHighlightSubtitleID: Int? = nil
    let speakerLabels: [String]
    var allowsEditing = true
    var showsSubtitleDisplayText = false
    var showsTranscriptCanvas = false
    var languageCode: String? = nil
    var sourceText: String? = nil
    let emptyText: String
    let onSeek: (Double, Double) -> Void

    @Bindable private var store = WorkbenchStore.shared
    @State private var editingCueID: Int?
    @State private var editingText = ""
    @State private var cursorOffset: Int?
    @State private var renameTarget: RenameSpeakerTarget?
    @State private var addSpeakerTarget: AddSpeakerTarget?
    @State private var colorTarget: SpeakerColorTarget?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var subtitleHighlightRanges: [Int: [Int: NSRange]] = [:]

    var body: some View {
        if cues.isEmpty {
            ContentUnavailableView(
                L10n.string("No segments"),
                systemImage: "text.alignleft",
                description: Text(L10n.display(emptyText))
            )
            .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.emptyStateMinHeight)
        } else {
            let highlights = highlightSubtitleCues.isEmpty ? nil :
                activeHighlightSubtitleID.flatMap { subtitleHighlightRanges[$0] } ?? [:]
            LazyVStack(alignment: .leading, spacing: showsTranscriptCanvas ? AppTheme.Spacing.xlXxl : 0) {
                if showsTranscriptCanvas {
                    ForEach(SessionTranscriptParagraph.group(cues)) { paragraph in
                        transcriptParagraph(paragraph, highlights: highlights)
                            .id(paragraph.id)
                    }
                } else {
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        cueRow(cue)
                            .id(cue.id)
                        if allowsEditing, index < cues.count - 1 {
                            SessionMergeDivider { mergeCue(cue.id) }
                        }
                    }
                }
            }
            // Transcript paragraphs and subtitle rows reuse cue IDs but have
            // different heights. Discard the lazy layout cache when switching
            // tracks, languages or presentation modes.
            .id(contentKey)
            .padding(.horizontal, showsTranscriptCanvas ? AppTheme.Spacing.sm : 0)
            .padding(.top, showsTranscriptCanvas ? AppTheme.Spacing.sm : 0)
            .task(id: allSpeakerLabels) {
                store.ensureSessionSpeakerColors(sessionID: sessionID, labels: allSpeakerLabels)
            }
            .task(id: [cues, highlightSubtitleCues]) {
                subtitleHighlightRanges = SessionTranscriptSubtitleHighlights.ranges(in: cues, subtitles: highlightSubtitleCues)
            }
            .popover(item: $colorTarget) { target in
                SessionSpeakerColorPicker(label: target.label, selection: colorBinding(for: target.label))
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
            .sheet(item: $addSpeakerTarget) { target in
                SessionAddSpeakerSheet(
                    existingLabels: allSpeakerLabels,
                    color: .next(excluding: Array(colors.values.values))
                ) { name, color in
                    assignSpeaker(name, cueIDs: target.cueIDs)
                    store.setSessionSpeakerColor(sessionID: sessionID, speaker: name, color: color)
                }
                .appZoomEnvironment(presentationBoundary: true)
            }
            .onChange(of: contentKey) { _, _ in
                resetEditingState()
            }
        }
    }

    private var allSpeakerLabels: [String] {
        var seen = Set<String>()
        return (speakerLabels + cues.compactMap(\.speaker)).compactMap {
            guard let label = SessionTranscriptParagraph.normalizedSpeaker($0), seen.insert(label).inserted else { return nil }
            return label
        }
    }

    private var colors: SessionSpeakerColors {
        store.sessionSpeakerColors(sessionID: sessionID, labels: allSpeakerLabels)
    }

    private func colorBinding(for label: String) -> Binding<SessionSpeakerColor> {
        Binding(
            get: { colors.values[label] ?? SessionSpeakerColor.presets[0] },
            set: { store.setSessionSpeakerColor(sessionID: sessionID, speaker: label, color: $0) }
        )
    }

    private func assignSpeaker(_ speaker: String, cueIDs: [Int]) {
        guard let label = SessionTranscriptParagraph.normalizedSpeaker(speaker) else { return }
        store.ensureSessionSpeakerColors(sessionID: sessionID, labels: allSpeakerLabels + [label])
        store.assignSessionCueSpeakers(sessionID: sessionID, scope: scope, cueIDs: cueIDs, speaker: label)
    }

    private func prepareAddSpeaker(cueIDs: [Int]) {
        addSpeakerTarget = AddSpeakerTarget(cueIDs: cueIDs)
    }

    private func mergeCue(_ id: Int) {
        if editingCueID == id { commitEditAndClose() }
        store.mergeSessionCueDown(sessionID: sessionID, scope: scope, cueID: id)
    }

    private func transcriptParagraph(_ paragraph: SessionTranscriptParagraph, highlights: [Int: NSRange]?) -> some View {
        let editedCue = paragraph.cues.first { $0.id == editingCueID }
        return SessionTranscriptParagraphView(
            paragraph: paragraph, activeCueID: activeCueID, highlightRanges: highlights, colors: colors,
            speakerLabels: allSpeakerLabels, allowsEditing: allowsEditing,
            languageCode: languageCode, sourceText: sourceText,
            editingCueID: editingCueID, editingText: editingBinding(for: editedCue ?? paragraph.cues[0]),
            cursorOffset: $cursorOffset, canSplit: canSplit,
            canMerge: { id in cues.last?.id != id }, onPlay: onSeek,
            onBeginEdit: beginEdit,
            onCommit: { if editingCueID == editedCue?.id { commitEditAndClose() } },
            onCancel: { if editingCueID == editedCue?.id { cancelEdit() } },
            onSplit: splitEditingCue, onMerge: mergeCue,
            onSelectSpeaker: { assignSpeaker($0, cueIDs: paragraph.cues.map(\.id)) },
            onSelectCueSpeaker: { id, label in assignSpeaker(label, cueIDs: [id]) },
            onRenameSpeaker: { renameTarget = RenameSpeakerTarget(label: $0) },
            onAddSpeaker: { prepareAddSpeaker(cueIDs: paragraph.cues.map(\.id)) },
            onAddCueSpeaker: { prepareAddSpeaker(cueIDs: [$0]) },
            onChangeColor: showColorPicker
        )
    }

    private func cueRow(_ cue: SubtitleCue) -> some View {
        SessionCueRow(
            cue: cue, isActive: activeCueID == cue.id, speakerLabels: allSpeakerLabels,
            isEditing: allowsEditing && editingCueID == cue.id,
            editingText: editingBinding(for: cue),
            cursorOffset: allowsEditing && editingCueID == cue.id ? $cursorOffset : .constant(nil),
            canSplit: allowsEditing && canSplit, allowsEditing: allowsEditing,
            showsSubtitleDisplayText: showsSubtitleDisplayText,
            onPlay: { onSeek(cue.start, cue.end) }, onBeginEdit: { beginEdit(cue) },
            onCommitEdit: commitEditAndClose, onCancelEdit: cancelEdit, onSplit: splitEditingCue,
            onSelectSpeaker: { assignSpeaker($0, cueIDs: [cue.id]) },
            onRenameSpeaker: { renameTarget = RenameSpeakerTarget(label: $0) },
            onAddSpeaker: { prepareAddSpeaker(cueIDs: [cue.id]) },
            speakerColor: cue.speaker.flatMap { colors.values[$0]?.labelColor } ?? AppTheme.Text.tertiaryColor,
            onChangeSpeakerColor: showColorPicker
        )
    }

    private func showColorPicker(_ label: String) {
        // Let AppKit finish closing the speaker menu before presenting a popover.
        DispatchQueue.main.async { colorTarget = SpeakerColorTarget(label: label) }
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
        if editingCueID != nil, editingCueID != cue.id { commitEditAndClose() }
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
    var speakerColor: Color = AppTheme.Text.tertiaryColor
    var onChangeSpeakerColor: ((String) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            Button(action: onPlay) {
                Image(systemName: isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Accent.link)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(isActive ? "Pause" : "Play from this segment"))

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
                    } else {
                        Text(
                            showsSubtitleDisplayText
                                ? TranscriptSegmenter.renderedSubtitleText(cue.text)
                                : cue.text
                        )
                            .font(.system(size: AppTheme.FontSize.mdLg))
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
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            isActive
                ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                : AppTheme.Background.surfaceColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(
                    isActive
                        ? AppTheme.Accent.primary
                        : isEditing
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted)
                            : AppTheme.Border.subtleColor,
                    lineWidth: isActive ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                )
        }
        .onHover { isHovered = $0 }
    }

    private var speakerMenu: some View {
        SessionSpeakerMenu(
            speaker: SessionTranscriptParagraph.normalizedSpeaker(cue.speaker),
            labels: speakerLabels, color: speakerColor,
            onSelect: onSelectSpeaker, onRename: onRenameSpeaker, onAdd: onAddSpeaker,
            onChangeColor: onChangeSpeakerColor
        )
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

private enum SessionCueEditorMetrics {
    static var font: NSFont { .systemFont(ofSize: AppTheme.FontSize.mdLg) }
    static var verticalInset: CGFloat { AppTheme.Spacing.xxs }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let font = font
        let inset = verticalInset
        let lineHeight = max(1, ceil(font.ascender - font.descender + font.leading))
        let minHeight = lineHeight + inset * 2
        guard width > 1 else { return minHeight }

        let sample = text.isEmpty ? " " : text
        let storage = NSTextStorage(string: sample, attributes: [.font: font])
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

struct SessionCueTextEditor: NSViewRepresentable {
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

private struct SpeakerColorTarget: Identifiable {
    let label: String
    var id: String { label }
}

private struct AddSpeakerTarget: Identifiable {
    let id = UUID()
    let cueIDs: [Int]
}
