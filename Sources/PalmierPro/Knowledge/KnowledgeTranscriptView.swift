import AppKit
import SwiftUI

private struct KnowledgeTranscriptLineFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct KnowledgeTranscriptView: View {
    let session: WorkbenchSession
    let target: KnowledgeTranscriptTarget?
    let onBack: () -> Void
    @FocusState private var isFocused: Bool
    @State private var playback = SessionPlaybackController()
    @State private var lineFrames: [String: CGRect] = [:]
    @State private var lastAutoScrolledLineID: String?
    @State private var lastAutoScrollDate: Date?
    @State private var lastCitationTarget: KnowledgeTranscriptTarget?

    private let scrollCoordinateSpace = "knowledge-transcript-scroll"
    private let playbackID: String

    init(
        session: WorkbenchSession,
        target: KnowledgeTranscriptTarget? = nil,
        onBack: @escaping () -> Void
    ) {
        self.session = session
        self.target = target
        self.onBack = onBack
        self.playbackID = "knowledge-transcript-\(session.id.uuidString)"
    }

    private var lines: [KnowledgeTranscriptLine] {
        guard let transcript = session.transcript else { return [] }
        if !transcript.segments.isEmpty {
            return transcript.segments.enumerated().map { index, segment in
                KnowledgeTranscriptLine(index: index, segment: segment)
            }
        }
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [KnowledgeTranscriptLine(id: "text", text: transcript.text, start: nil, end: nil, speaker: nil)]
    }

    private var playbackCues: [SubtitleCue] {
        lines.compactMap { line in
            guard let index = line.index,
                  let start = line.start,
                  let end = line.end,
                  start.isFinite,
                  end.isFinite,
                  end > start else { return nil }
            return SubtitleCue(
                id: index,
                sourceIDs: [],
                text: line.text,
                start: start,
                end: end,
                speaker: line.speaker
            )
        }
    }

    private var citationLineID: String? {
        guard let target,
              let transcript = session.transcript,
              let index = KnowledgeTranscriptNavigation.segmentIndex(
                  for: target,
                  in: transcript.segments
              ),
              lines.indices.contains(index)
        else { return nil }
        return lines[index].id
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                            if lines.isEmpty {
                                Text(L10n.string("No transcript available."))
                                    .font(.system(size: AppTheme.FontSize.sm))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, AppTheme.Spacing.xxl)
                            } else {
                                ForEach(lines) { line in
                                    transcriptLine(line)
                                        .id(line.id)
                                }
                            }
                        }
                        .padding(AppTheme.Spacing.md)
                    }
                    .coordinateSpace(name: scrollCoordinateSpace)
                    .onPreferenceChange(KnowledgeTranscriptLineFramesKey.self) { frames in
                        lineFrames = frames
                        scrollToCitationIfNeeded(proxy: proxy)
                    }
                    .onAppear {
                        scrollToCitationIfNeeded(proxy: proxy)
                        autoScrollIfNeeded(
                            activeCueID: playback.activeCueID,
                            proxy: proxy,
                            viewportHeight: viewport.size.height
                        )
                    }
                    .onChange(of: target) { _, _ in
                        scrollToCitationIfNeeded(proxy: proxy)
                    }
                    .onChange(of: playback.activeCueID) { _, activeCueID in
                        autoScrollIfNeeded(
                            activeCueID: activeCueID,
                            proxy: proxy,
                            viewportHeight: viewport.size.height
                        )
                    }
                }
            }
        }
        .background(AppTheme.Background.surfaceColor)
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onDisappear {
            playback.tearDown()
            AudioPlaybackCoordinator.shared.end(id: playbackID)
        }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            if isPlaying {
                AudioPlaybackCoordinator.shared.begin(id: playbackID) {
                    playback.stop()
                }
            } else {
                AudioPlaybackCoordinator.shared.end(id: playbackID)
            }
        }
        .task(id: session.id) {
            playback.configureHighlightCues(playbackCues)
            await playback.load(url: session.preferredPlaybackURL, showsVideoCanvas: false)
        }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
            onBack()
            return .handled
        }
        .onKeyPress(.space, phases: [.down]) { _ in
            togglePlayback()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                Text(L10n.string("Back"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .accessibilityLabel(Text(L10n.string("Back to knowledge list")))

            Divider()
                .frame(height: AppTheme.IconSize.md)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(session.title.isEmpty ? L10n.string("Untitled session") : session.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Text(L10n.string("Transcript"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.zero)

            KnowledgeTranscriptCopyButton(
                value: lines.map(\.text).joined(separator: "\n"),
                helpText: L10n.string("Copy all transcript")
            )
            .disabled(lines.isEmpty)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(height: AppTheme.Workbench.toolbarHeight)
        .background(AppTheme.Background.surfaceColor)
    }

    private func transcriptLine(_ line: KnowledgeTranscriptLine) -> some View {
        let isActive = line.index != nil && playback.activeCueID == line.index
        let isCitationTarget = line.id == citationLineID
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                if let start = line.start, let end = line.end, end > start {
                    Button {
                        togglePlayback(for: line)
                    } label: {
                        Image(systemName: isActive && playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                            .foregroundStyle(isActive ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                            .background(
                                Circle()
                                    .fill(isActive ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : AppTheme.Background.baseColor)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(playback.player == nil)
                    .help(L10n.string(isActive && playback.isPlaying ? "Pause transcript" : "Play transcript"))
                    .accessibilityLabel(Text(L10n.string(isActive && playback.isPlaying ? "Pause transcript" : "Play transcript")))
                }

                if let timeLabel = timeLabel(for: line) {
                    Text(timeLabel)
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Accent.timecodeColor)
                }

                if let speaker = line.speaker, !speaker.isEmpty {
                    Text(speaker)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                        )
                }

                Spacer(minLength: AppTheme.Spacing.zero)

                if isCitationTarget {
                    Image(systemName: "scope")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .help(L10n.string("Citation match"))
                }

                KnowledgeTranscriptCopyButton(
                    value: line.text,
                    helpText: L10n.string("Copy segment")
                )
                .disabled(line.text.isEmpty)
            }

            highlightedText(line.text, match: isCitationTarget ? target?.matchText : nil)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(
                    isCitationTarget
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                            : isActive
                                ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                            : AppTheme.Background.raisedColor
                )
        )
        .overlay {
            if isCitationTarget {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: KnowledgeTranscriptLineFramesKey.self,
                    value: [line.id: geometry.frame(in: .named(scrollCoordinateSpace))]
                )
            }
        }
    }

    private func timeLabel(for line: KnowledgeTranscriptLine) -> String? {
        guard let start = line.start else { return nil }
        let startLabel = KnowledgeSourceRef.formatTimestamp(start)
        guard let end = line.end, end > start else { return startLabel }
        return "\(startLabel) – \(KnowledgeSourceRef.formatTimestamp(end))"
    }

    private func togglePlayback(for line: KnowledgeTranscriptLine) {
        guard let start = line.start, let end = line.end, end > start else { return }
        beginPlaybackIfNeeded()
        playback.toggleCuePlayback(start: start, end: end)
    }

    private func togglePlayback() {
        guard playback.player != nil else { return }
        beginPlaybackIfNeeded()
        playback.togglePlayback()
    }

    private func beginPlaybackIfNeeded() {
        AudioPlaybackCoordinator.shared.begin(id: playbackID) {
            playback.stop()
        }
    }

    private func scrollToCitationIfNeeded(proxy: ScrollViewProxy) {
        guard let citationLineID,
              target != lastCitationTarget
        else { return }

        lastCitationTarget = target
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            proxy.scrollTo(citationLineID, anchor: .center)
        }
    }

    private func highlightedText(_ text: String, match: String?) -> Text {
        KnowledgeTranscriptTextHighlighter.text(text, matching: match)
    }

    private func autoScrollIfNeeded(
        activeCueID: Int?,
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat
    ) {
        guard let activeCueID,
              let line = lines.first(where: { $0.index == activeCueID }),
              viewportHeight > AppTheme.Spacing.zero else { return }

        let frame = lineFrames[line.id]
        let isVisible = frame.map { $0.minY >= AppTheme.Spacing.zero && $0.maxY <= viewportHeight } ?? false
        guard !isVisible else { return }

        let now = Date()
        if lastAutoScrolledLineID == line.id {
            return
        }
        if let lastAutoScrollDate,
           now.timeIntervalSince(lastAutoScrollDate) < AppTheme.Knowledge.transcriptAutoScrollCooldown {
            return
        }

        lastAutoScrolledLineID = line.id
        lastAutoScrollDate = now
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            proxy.scrollTo(line.id, anchor: .top)
        }
    }
}

private struct KnowledgeTranscriptCopyButton: View {
    private static let feedbackDuration: Duration = .seconds(1.4)

    let value: String
    let helpText: String
    @State private var status: CopyStatus = .idle
    @State private var feedbackID: UUID?

    init(value: String, helpText: String) {
        self.value = value
        self.helpText = helpText
    }

    var body: some View {
        Button(action: copy) {
            Image(systemName: status.iconName)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(status.tint)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .contentTransition(.symbolEffect(.replace))
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(status == .copied ? L10n.string("Copied") : status == .failed ? L10n.string("Copy failed") : helpText)
        .accessibilityLabel(Text(status == .copied ? L10n.string("Copied") : status == .failed ? L10n.string("Copy failed") : helpText))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else {
            status = .failed
            return
        }

        let copyID = UUID()
        feedbackID = copyID
        status = .copied
        Task {
            try? await Task.sleep(for: Self.feedbackDuration)
            if feedbackID == copyID {
                status = .idle
            }
        }
    }

    private enum CopyStatus: Equatable {
        case idle
        case copied
        case failed

        var iconName: String {
            switch self {
            case .idle: "doc.on.doc"
            case .copied: "checkmark"
            case .failed: "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .idle: AppTheme.Text.secondaryColor
            case .copied: AppTheme.Accent.primary
            case .failed: AppTheme.Status.errorColor
            }
        }

    }
}

private enum KnowledgeTranscriptTextHighlighter {
    static func text(_ text: String, matching query: String?) -> Text {
        let ranges = matchingRanges(in: text, query: query)
        guard !ranges.isEmpty else { return Text(text) }

        var result = Text("")
        var cursor = text.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result = result + Text(String(text[cursor..<range.lowerBound]))
            }
            result = result + Text(String(text[range]))
                .bold()
                .foregroundColor(AppTheme.Accent.primary)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result = result + Text(String(text[cursor..<text.endIndex]))
        }
        return result
    }

    private static func matchingRanges(
        in text: String,
        query: String?
    ) -> [Range<String.Index>] {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return [] }

        var candidates = [query]
        candidates.append(contentsOf: query.split(whereSeparator: \.isWhitespace).map(String.init))

        let characters = Array(query)
        if characters.count > 1 {
            let maxLength = min(characters.count, 8)
            for length in stride(from: maxLength, through: 2, by: -1) {
                guard characters.count >= length else { continue }
                for start in 0...(characters.count - length) {
                    candidates.append(String(characters[start..<(start + length)]))
                }
            }
        }

        for candidate in candidates.sorted(by: { $0.count > $1.count }) {
            let ranges = allRanges(in: text, matching: candidate)
            if !ranges.isEmpty { return ranges }
        }
        return []
    }

    private static func allRanges(in text: String, matching query: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<text.endIndex
              )
        {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}

private struct KnowledgeTranscriptLine: Identifiable {
    let id: String
    let index: Int?
    let text: String
    let start: Double?
    let end: Double?
    let speaker: String?

    init(index: Int, segment: TranscriptionSegment) {
        self.init(
            id: "\(index)-\(segment.start)-\(segment.end)",
            index: index,
            text: segment.text,
            start: segment.start,
            end: segment.end,
            speaker: segment.speaker
        )
    }

    init(id: String, text: String, start: Double?, end: Double?, speaker: String?) {
        self.init(id: id, index: nil, text: text, start: start, end: end, speaker: speaker)
    }

    private init(id: String, index: Int?, text: String, start: Double?, end: Double?, speaker: String?) {
        self.id = id
        self.index = index
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}
