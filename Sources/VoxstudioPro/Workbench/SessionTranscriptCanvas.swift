import AppKit
import SwiftUI

/// Presentation-only grouping. Cue IDs, boundaries, source IDs and text remain intact.
struct SessionTranscriptParagraph: Identifiable {
    var cues: [SubtitleCue]
    var id: Int { cues[0].id }
    var speaker: String? { Self.normalizedSpeaker(cues[0].speaker) }
    var start: Double { cues.map(\.start).min() ?? 0 }
    var end: Double { cues.map(\.end).max() ?? start }

    static func normalizedSpeaker(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func group(_ cues: [SubtitleCue]) -> [Self] {
        var result: [Self] = []
        for cue in cues {
            let speaker = normalizedSpeaker(cue.speaker)
            if let last = result.indices.last, speaker != nil, result[last].speaker == speaker {
                result[last].cues.append(cue)
            } else {
                result.append(Self(cues: [cue]))
            }
        }
        return result
    }

    static func scrollID(for cueID: Int, in cues: [SubtitleCue]) -> Int? {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return nil }
        guard let speaker = normalizedSpeaker(cues[index].speaker) else { return cueID }
        var first = index
        while first > 0, normalizedSpeaker(cues[first - 1].speaker) == speaker { first -= 1 }
        return cues[first].id
    }

    struct Piece {
        let cue: SubtitleCue
        let separator: String
        let text: String
    }

    /// Preserve authored text in every script. Use the original transcript's
    /// separators when available, and the shared track-aware joiner otherwise.
    /// There is no language whitelist or English/Chinese branch in the canvas.
    static func pieces(_ cues: [SubtitleCue], language: String? = nil, sourceText: String? = nil) -> [Piece] {
        var result: [Piece] = []
        var previous = ""
        var previousSourceEnd: String.Index?
        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var separator = ""
            if !previous.isEmpty {
                let joined = TranscriptSegmenter.joinedText([previous, text], language: language)
                let contentLength = TranscriptSegmenter.normalizeDisplayText(previous, language: language).count
                    + TranscriptSegmenter.normalizeDisplayText(text, language: language).count
                separator = joined.count > contentLength ? " " : ""
            }
            if let sourceText {
                let searchStart = previousSourceEnd ?? sourceText.startIndex
                if let range = sourceText.range(of: text, range: searchStart..<sourceText.endIndex) {
                    if let previousSourceEnd {
                        let original = sourceText[previousSourceEnd..<range.lowerBound]
                        if original.allSatisfy(\.isWhitespace), !original.contains(where: \.isNewline) {
                            separator = original.isEmpty ? "" : " "
                        }
                    }
                    previousSourceEnd = range.upperBound
                } else {
                    previousSourceEnd = nil
                }
            }
            result.append(Piece(cue: cue, separator: separator, text: text))
            previous = text
        }
        return result
    }

    static func text(_ cues: [SubtitleCue], language: String? = nil, sourceText: String? = nil) -> String {
        pieces(cues, language: language, sourceText: sourceText).map { $0.separator + $0.text }.joined()
    }
}

/// Maps subtitle text back to the authored transcript without replacing its
/// segments or editing IDs. Whitespace/wrapping may differ between the tracks.
enum SessionTranscriptSubtitleHighlights {
    static func range(for cue: SubtitleCue, activeCueID: Int?, subtitleRanges: [Int: NSRange]?) -> NSRange? {
        if let subtitleRanges { return subtitleRanges[cue.id] }
        guard cue.id == activeCueID else { return nil }
        return NSRange(location: 0, length: cue.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)
    }

    static func ranges(in cues: [SubtitleCue], subtitles: [SubtitleCue]) -> [Int: [Int: NSRange]] {
        guard !cues.isEmpty, !subtitles.isEmpty else { return [:] }
        struct Position {
            let cueID: Int
            let offset: Int
            let length: Int
        }
        var normalized = ""
        var positions: [Position] = []
        var spans: [NSRange] = []
        for cue in cues {
            let start = positions.count
            var offset = 0
            for character in cue.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                let length = String(character).utf16.count
                if !character.isWhitespace {
                    normalized.append(character)
                    positions.append(contentsOf: Array(repeating: Position(cueID: cue.id, offset: offset, length: length), count: length))
                }
                offset += length
            }
            spans.append(NSRange(location: start, length: positions.count - start))
        }
        let source = normalized as NSString
        var cursor = 0
        var result: [Int: [Int: NSRange]] = [:]
        for subtitle in subtitles {
            guard subtitle.start.isFinite, subtitle.end.isFinite, subtitle.end > subtitle.start else { continue }
            let overlapping = cues.indices.filter {
                cues[$0].start < subtitle.end && cues[$0].end > subtitle.start
            }
            guard let first = overlapping.first, let last = overlapping.last else { continue }
            let start = max(cursor, spans[first].location)
            let end = NSMaxRange(spans[last])
            let text = String(subtitle.text.filter { !$0.isWhitespace })
            guard !text.isEmpty, start < end else { continue }
            let match = source.range(of: text, options: .literal, range: NSRange(location: start, length: end - start))
            guard match.location != NSNotFound else { continue }
            var ranges: [Int: NSRange] = [:]
            for position in positions[match.location..<NSMaxRange(match)] {
                let range = NSRange(location: position.offset, length: position.length)
                ranges[position.cueID] = ranges[position.cueID].map { NSUnionRange($0, range) } ?? range
            }
            result[subtitle.id] = ranges
            cursor = NSMaxRange(match)
        }
        return result
    }
}

struct SessionSpeakerMenu: View {
    let speaker: String?
    let labels: [String]
    let color: Color
    var prominent = false
    let onSelect: (String) -> Void
    let onRename: (String) -> Void
    let onAdd: () -> Void
    var onChangeColor: ((String) -> Void)? = nil
    @Environment(\.sessionSpeakerVoiceContext) private var voiceContext

    var body: some View {
        Menu {
            ForEach(labels, id: \.self) { label in
                Button { onSelect(label) } label: {
                    if speaker == label { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
            if !labels.isEmpty { Divider() }
            Button(L10n.string("Add speaker…"), action: onAdd)
            if let speaker, !speaker.isEmpty {
                Button(L10n.format("Rename %@…", speaker)) { onRename(speaker) }
                if let onChangeColor {
                    Button(L10n.string("Change color…")) { onChangeColor(speaker) }
                }
                if let voiceContext {
                    SessionSpeakerVoiceMenuSection(speaker: speaker, context: voiceContext)
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                SessionSpeakerIdentityGlyph(speaker: speaker)
                Text(speaker ?? L10n.string("Speaker"))
                    .font(.system(size: prominent ? AppTheme.FontSize.lg : AppTheme.FontSize.xs,
                                  weight: prominent ? .semibold : .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.vertical, AppTheme.Spacing.xxs)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(L10n.string("Assign speaker"))
    }
}

struct SessionTranscriptParagraphView: View {
    let paragraph: SessionTranscriptParagraph
    let activeCueID: Int?
    /// nil retains segment highlighting for transcripts without subtitle cuts.
    let highlightRanges: [Int: NSRange]?
    let colors: SessionSpeakerColors
    let speakerLabels: [String]
    let allowsEditing: Bool
    let languageCode: String?
    let sourceText: String?
    let editingCueID: Int?
    @Binding var editingText: String
    @Binding var cursorOffset: Int?
    let canSplit: Bool
    let canMerge: (Int) -> Bool
    let onPlay: (Double, Double) -> Void
    let onBeginEdit: (SubtitleCue) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onSplit: () -> Void
    let onMerge: (Int) -> Void
    let onSelectSpeaker: (String) -> Void
    let onSelectCueSpeaker: (Int, String) -> Void
    let onRenameSpeaker: (String) -> Void
    let onAddSpeaker: () -> Void
    let onAddCueSpeaker: (Int) -> Void
    let onChangeColor: (String) -> Void
    @State private var isHovered = false

    private var speakerColor: Color {
        paragraph.speaker.flatMap { colors.values[$0]?.labelColor } ?? AppTheme.Text.secondaryColor
    }

    private var activeCue: SubtitleCue? { paragraph.cues.first { $0.id == activeCueID } }
    private var editingIndex: Int? { paragraph.cues.firstIndex { $0.id == editingCueID } }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.mdLg) {
            Button {
                onPlay(activeCue?.start ?? paragraph.start, paragraph.end)
            } label: {
                Image(systemName: activeCue == nil ? "play.fill" : "pause.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(activeCue == nil ? AppTheme.Text.tertiaryColor : speakerColor)
                    .frame(width: AppTheme.zoomed(28), height: AppTheme.zoomed(28))
                    .background(activeCue == nil ? AppTheme.Text.primaryColor.opacity(0.035) : speakerColor.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(activeCue == nil ? "Play from this segment" : "Pause"))
            .accessibilityLabel(L10n.string(activeCue == nil ? "Play from this segment" : "Pause"))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.smMd) {
                    if allowsEditing {
                        SessionSpeakerMenu(
                            speaker: paragraph.speaker, labels: speakerLabels, color: speakerColor,
                            prominent: true, onSelect: onSelectSpeaker, onRename: onRenameSpeaker,
                            onAdd: onAddSpeaker, onChangeColor: onChangeColor
                        )
                    } else {
                        Text(paragraph.speaker ?? L10n.string("Speaker"))
                            .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                            .foregroundStyle(speakerColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Text(Self.timeRange(start: paragraph.start, end: paragraph.end))
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize()
                    if allowsEditing {
                        Button { onBeginEdit(activeCue ?? paragraph.cues[0]) } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovered || editingIndex != nil ? 1 : 0)
                        .help(L10n.string("Edit text"))
                        .accessibilityLabel(L10n.string("Edit text"))
                    }
                }
                paragraphContent
            }
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var paragraphContent: some View {
        if let index = editingIndex {
            let cue = paragraph.cues[index]
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                if index > 0 { readingText(Array(paragraph.cues[..<index])) }
                SessionCueTextEditor(text: $editingText, cursorOffset: $cursorOffset,
                                     onCommit: onCommit, onCancel: onCancel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .background(speakerColor.opacity(0.06), in: RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm))
                HStack(spacing: AppTheme.Spacing.mdLg) {
                    SessionSpeakerMenu(
                        speaker: SessionTranscriptParagraph.normalizedSpeaker(cue.speaker),
                        labels: speakerLabels, color: speakerColor,
                        onSelect: { onSelectCueSpeaker(cue.id, $0) }, onRename: onRenameSpeaker,
                        onAdd: { onAddCueSpeaker(cue.id) }, onChangeColor: onChangeColor
                    )
                    Text(Self.timeRange(start: cue.start, end: cue.end))
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer()
                    if canSplit {
                        Button(action: onSplit) { Image(systemName: "scissors") }
                            .help(L10n.string("Split at cursor"))
                            .accessibilityLabel(L10n.string("Split at cursor"))
                    }
                    if canMerge(cue.id) {
                        Button { onMerge(cue.id) } label: { Image(systemName: "arrow.triangle.merge") }
                            .help(L10n.string("Merge with segment below"))
                            .accessibilityLabel(L10n.string("Merge with segment below"))
                    }
                    Button(L10n.string("Done"), action: onCommit)
                }
                .buttonStyle(.borderless)
                .font(.system(size: AppTheme.FontSize.xs))
                if index + 1 < paragraph.cues.count { readingText(Array(paragraph.cues[(index + 1)...])) }
            }
        } else {
            readingText(paragraph.cues)
        }
    }

    private func readingText(_ cues: [SubtitleCue]) -> some View {
        Text(attributedText(cues))
            .font(.system(size: AppTheme.FontSize.lg))
            .lineSpacing(AppTheme.zoomed(4))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "voxstudio-cue", let id = Int(url.host ?? ""),
                      let cue = cues.first(where: { $0.id == id }) else { return .discarded }
                if allowsEditing { onBeginEdit(cue) }
                else { onPlay(cue.start, paragraph.end) }
                return .handled
            })
            .contextMenu {
                Button(L10n.string("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SessionTranscriptParagraph.text(cues, language: languageCode, sourceText: sourceText), forType: .string)
                }
                if allowsEditing {
                    Button(L10n.string("Edit text")) { onBeginEdit(activeCue ?? cues[0]) }
                }
            }
    }

    private func attributedText(_ cues: [SubtitleCue]) -> AttributedString {
        var result = AttributedString()
        for fragment in SessionTranscriptParagraph.pieces(cues, language: languageCode, sourceText: sourceText) {
            let cue = fragment.cue
            result += AttributedString(fragment.separator)
            var piece = AttributedString(fragment.text)
            piece.link = URL(string: "voxstudio-cue://\(cue.id)")
            piece.foregroundColor = AppTheme.Text.primaryColor
            piece.underlineStyle = nil
            if let range = SessionTranscriptSubtitleHighlights.range(for: cue, activeCueID: activeCueID, subtitleRanges: highlightRanges),
               let stringRange = Range(range, in: fragment.text),
               let lower = AttributedString.Index(stringRange.lowerBound, within: piece),
               let upper = AttributedString.Index(stringRange.upperBound, within: piece) {
                piece[lower..<upper].backgroundColor = speakerColor.opacity(0.12)
            }
            result += piece
        }
        return result
    }

    static func timeRange(start: Double, end: Double) -> String {
        func time(_ value: Double) -> String {
            let safe = value.isFinite ? max(0, value) : 0
            return String(format: "%02d:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
        }
        return "\(time(start)) — \(time(end))"
    }
}
