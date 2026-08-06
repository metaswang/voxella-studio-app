import AppKit
import Foundation
import UniformTypeIdentifiers

enum SessionExportContent: String, CaseIterable, Identifiable, Sendable {
    case transcript
    case subtitle
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .subtitle: "Subtitles"
        case .audio: "Audio"
        }
    }

    var hint: String {
        switch self {
        case .transcript: "Review-friendly text with speaker-aware structure."
        case .subtitle: "Timed captions for editors and publishing tools."
        case .audio: "Export the source recording or dubbed result."
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: "doc.plaintext"
        case .subtitle: "captions.bubble"
        case .audio: "waveform"
        }
    }
}

enum SessionExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt
    case vtt
    case srt
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: "TXT"
        case .vtt: "VTT"
        case .srt: "SRT"
        case .audio: "Audio"
        }
    }

    var hint: String {
        switch self {
        case .txt: "Plain text for sharing and reuse."
        case .vtt: "Best for web and player workflows."
        case .srt: "Best for editors and subtitle platforms."
        case .audio: "Copy the source or dubbed audio file."
        }
    }

    var systemImage: String {
        switch self {
        case .txt: "textformat"
        case .vtt: "captions.bubble"
        case .srt: "doc.text"
        case .audio: "waveform"
        }
    }

    var pathExtension: String {
        switch self {
        case .txt: "txt"
        case .vtt: "vtt"
        case .srt: "srt"
        case .audio: "m4a"
        }
    }

    var contentType: UTType {
        switch self {
        case .txt: .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .audio: .audio
        }
    }
}

enum SessionExportVariant: String, CaseIterable, Identifiable, Sendable {
    case original
    case translation
    case bilingual
    case dub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Original"
        case .translation: "Translation"
        case .bilingual: "Bilingual"
        case .dub: "Dubbed Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .original: "doc.plaintext"
        case .translation: "globe"
        case .bilingual: "arrow.left.arrow.right"
        case .dub: "waveform.and.mic"
        }
    }
}

enum SessionExportTranslationOrder: String, CaseIterable, Identifiable, Sendable {
    case translationFirst = "translation_first"
    case originalFirst = "original_first"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translationFirst: "Translation First"
        case .originalFirst: "Original First"
        }
    }

    var hint: String {
        switch self {
        case .translationFirst: "Best when readers care about the translated meaning first."
        case .originalFirst: "Best for linguistic review and line-by-line verification."
        }
    }
}

enum SessionExportAction: String, CaseIterable, Identifiable, Sendable {
    case download
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: "Download"
        case .copy: "Copy"
        }
    }

    var hint: String {
        switch self {
        case .download: "Save a file locally for editing, upload, or archive."
        case .copy: "Send the text directly to your clipboard."
        }
    }

    var systemImage: String {
        switch self {
        case .download: "square.and.arrow.down"
        case .copy: "doc.on.doc"
        }
    }
}

struct SessionExportAvailability: Equatable, Sendable {
    var transcript = false
    var subtitle = false
    var audio = false
    var dubbedAudio = false
    var translationTracks: [WorkbenchTranslationTrack] = []

    var hasTranslation: Bool { !translationTracks.isEmpty }

    static func from(_ session: WorkbenchSession) -> SessionExportAvailability {
        let hasTranscript = !(session.transcript?.segments.isEmpty ?? true)
            || !(session.transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSubtitle = !(session.subtitleTrack?.cues.isEmpty ?? true)
            || !(session.dubSubtitleTrack?.cues.isEmpty ?? true)
        return SessionExportAvailability(
            transcript: hasTranscript || !session.dubSegments.isEmpty,
            subtitle: hasSubtitle,
            audio: session.sourceURL != nil,
            dubbedAudio: session.outputURL != nil,
            translationTracks: session.translationTracks.filter { !$0.track.cues.isEmpty }
        )
    }
}

struct SessionExportDraft: Equatable, Sendable {
    var content: SessionExportContent = .transcript
    var format: SessionExportFormat = .txt
    var variant: SessionExportVariant = .original
    var targetLanguage: String?
    var translationOrder: SessionExportTranslationOrder = .translationFirst
    var action: SessionExportAction = .download
    var includeSpeakers = true
    var includeTimestamps = false

    mutating func normalize(against availability: SessionExportAvailability) {
        if content == .transcript, !availability.transcript {
            content = availability.subtitle ? .subtitle
                : (availability.audio || availability.dubbedAudio) ? .audio
                : .transcript
        }
        if content == .subtitle, !availability.subtitle {
            content = availability.transcript ? .transcript
                : (availability.audio || availability.dubbedAudio) ? .audio
                : .subtitle
        }
        if content == .audio, !availability.audio, !availability.dubbedAudio {
            content = availability.transcript ? .transcript
                : availability.subtitle ? .subtitle
                : .audio
        }

        switch content {
        case .audio:
            format = .audio
            action = .download
            includeSpeakers = false
            includeTimestamps = false
            if variant == .dub {
                if !availability.dubbedAudio {
                    variant = availability.audio ? .original : .dub
                }
            } else {
                variant = availability.audio ? .original : .dub
            }
            targetLanguage = nil
        case .transcript, .subtitle:
            if format == .audio {
                format = .txt
            }
            if variant == .dub {
                variant = .original
            }
            if variant == .bilingual, content == .subtitle, format != .txt {
                variant = availability.hasTranslation ? .translation : .original
            }
            if variant == .translation || variant == .bilingual, !availability.hasTranslation {
                variant = .original
            }
            if variant == .translation || (content == .subtitle && variant == .translation) {
                if targetLanguage == nil
                    || !availability.translationTracks.contains(where: {
                        $0.languageCode.caseInsensitiveCompare(targetLanguage ?? "") == .orderedSame
                    }) {
                    targetLanguage = availability.translationTracks.first?.languageCode
                }
            } else if variant != .bilingual {
                targetLanguage = nil
            } else if targetLanguage == nil {
                targetLanguage = availability.translationTracks.first?.languageCode
            }
            if format != .txt {
                includeSpeakers = false
                includeTimestamps = false
            }
        }
    }

    static func `default`(
        for availability: SessionExportAvailability,
        preferredContent: SessionExportContent? = nil
    ) -> SessionExportDraft {
        var draft = SessionExportDraft()
        if let preferredContent {
            draft.content = preferredContent
        } else if availability.transcript {
            draft.content = .transcript
        } else if availability.subtitle {
            draft.content = .subtitle
        } else {
            draft.content = .audio
        }
        draft.includeSpeakers = draft.content == .transcript
        draft.includeTimestamps = draft.content == .subtitle
        draft.normalize(against: availability)
        return draft
    }

    var summaryLabel: String {
        let contentLabel = content.title
        let variantLabel = variant.title
        let formatLabel = content == .audio ? "Audio" : format.title
        return "\(contentLabel) · \(variantLabel) · \(formatLabel)"
    }
}

struct SessionExportSegment: Sendable {
    var start: Double
    var end: Double
    var text: String
    var translationText: String?
    var speaker: String?
}

enum SessionExportFormatter {
    static func render(
        segments: [SessionExportSegment],
        format: SessionExportFormat,
        variant: SessionExportVariant,
        translationOrder: SessionExportTranslationOrder,
        includeSpeakers: Bool,
        includeTimestamps: Bool,
        stripEdgePunctuation: Bool
    ) -> String {
        switch format {
        case .txt:
            return renderTXT(
                segments: segments,
                variant: variant,
                translationOrder: translationOrder,
                includeSpeakers: includeSpeakers,
                includeTimestamps: includeTimestamps,
                stripEdgePunctuation: stripEdgePunctuation
            )
        case .vtt:
            return renderVTT(
                segments: segments,
                variant: variant,
                translationOrder: translationOrder,
                stripEdgePunctuation: stripEdgePunctuation
            )
        case .srt:
            return renderSRT(
                segments: segments,
                variant: variant,
                translationOrder: translationOrder,
                stripEdgePunctuation: stripEdgePunctuation
            )
        case .audio:
            return ""
        }
    }

    private static func payloadLines(
        originalText: String,
        translationText: String?,
        variant: SessionExportVariant,
        translationOrder: SessionExportTranslationOrder,
        stripEdgePunctuation: Bool
    ) -> [String] {
        let original = stripEdgePunctuation
            ? stripEdgePunct(originalText)
            : originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = stripEdgePunctuation
            ? stripEdgePunct(translationText ?? "")
            : (translationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch variant {
        case .translation:
            let line = translated.isEmpty ? original : translated
            return line.isEmpty ? [] : [line]
        case .bilingual:
            var first = translated.isEmpty ? original : translated
            var second = original
            if translationOrder == .originalFirst {
                first = original
                second = translated.isEmpty ? original : translated
            }
            var lines = [first, second].filter { !$0.isEmpty }
            if lines.count == 2, lines[0] == lines[1] {
                lines = [lines[0]]
            }
            return lines
        case .original, .dub:
            return original.isEmpty ? [] : [original]
        }
    }

    private static func renderTXT(
        segments: [SessionExportSegment],
        variant: SessionExportVariant,
        translationOrder: SessionExportTranslationOrder,
        includeSpeakers: Bool,
        includeTimestamps: Bool,
        stripEdgePunctuation: Bool
    ) -> String {
        var blocks: [String] = []
        for segment in segments {
            let payload = payloadLines(
                originalText: segment.text,
                translationText: segment.translationText,
                variant: variant,
                translationOrder: translationOrder,
                stripEdgePunctuation: stripEdgePunctuation
            )
            guard !payload.isEmpty else { continue }

            var headerParts: [String] = []
            if includeTimestamps {
                headerParts.append("[\(formatTimestampPlain(segment.start))]")
            }
            let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if includeSpeakers, !speaker.isEmpty {
                headerParts.append("\(speaker):")
            }

            if payload.count == 1 {
                blocks.append(([headerParts, [payload[0]]].flatMap { $0 }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                var blockLines: [String] = []
                if !headerParts.isEmpty {
                    blockLines.append(headerParts.joined(separator: " "))
                }
                blockLines.append(contentsOf: payload)
                blocks.append(blockLines.joined(separator: "\n"))
            }
        }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func renderVTT(
        segments: [SessionExportSegment],
        variant: SessionExportVariant,
        translationOrder: SessionExportTranslationOrder,
        stripEdgePunctuation: Bool
    ) -> String {
        var lines = ["WEBVTT", ""]
        for segment in segments {
            let payload = payloadLines(
                originalText: segment.text,
                translationText: segment.translationText,
                variant: variant,
                translationOrder: translationOrder,
                stripEdgePunctuation: stripEdgePunctuation
            )
            guard !payload.isEmpty else { continue }
            lines.append("\(formatTimestampVTT(segment.start)) --> \(formatTimestampVTT(segment.end))")
            lines.append(contentsOf: payload)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func renderSRT(
        segments: [SessionExportSegment],
        variant: SessionExportVariant,
        translationOrder: SessionExportTranslationOrder,
        stripEdgePunctuation: Bool
    ) -> String {
        var lines: [String] = []
        var index = 1
        for segment in segments {
            let payload = payloadLines(
                originalText: segment.text,
                translationText: segment.translationText,
                variant: variant,
                translationOrder: translationOrder,
                stripEdgePunctuation: stripEdgePunctuation
            )
            guard !payload.isEmpty else { continue }
            lines.append(String(index))
            lines.append("\(formatTimestampSRT(segment.start)) --> \(formatTimestampSRT(segment.end))")
            lines.append(contentsOf: payload)
            lines.append("")
            index += 1
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func stripEdgePunct(_ text: String) -> String {
        TranscriptSegmenter.renderedSubtitleText(text)
    }

    private static func clampedMilliseconds(_ seconds: Double) -> Int {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        return Int((safe * 1000).rounded())
    }

    private static func formatTimestampPlain(_ seconds: Double) -> String {
        let totalMs = clampedMilliseconds(seconds)
        let totalS = totalMs / 1000
        let s = totalS % 60
        let totalM = totalS / 60
        let m = totalM % 60
        let h = totalM / 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private static func formatTimestampVTT(_ seconds: Double) -> String {
        let totalMs = clampedMilliseconds(seconds)
        let ms = totalMs % 1000
        let totalS = totalMs / 1000
        let s = totalS % 60
        let totalM = totalS / 60
        let m = totalM % 60
        let h = totalM / 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func formatTimestampSRT(_ seconds: Double) -> String {
        let totalMs = clampedMilliseconds(seconds)
        let ms = totalMs % 1000
        let totalS = totalMs / 1000
        let s = totalS % 60
        let totalM = totalS / 60
        let m = totalM % 60
        let h = totalM / 60
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

enum SessionExportBuilder {
    static func segments(
        for session: WorkbenchSession,
        draft: SessionExportDraft
    ) throws -> [SessionExportSegment] {
        switch draft.content {
        case .audio:
            return []
        case .transcript:
            return try transcriptSegments(for: session, draft: draft)
        case .subtitle:
            return try subtitleSegments(for: session, draft: draft)
        }
    }

    static func suggestedFilename(
        session: WorkbenchSession,
        draft: SessionExportDraft,
        audioURL: URL? = nil
    ) -> String {
        let base = sanitizeFilename(session.title)
        switch draft.content {
        case .audio:
            let ext = audioURL?.pathExtension.isEmpty == false
                ? audioURL!.pathExtension
                : "m4a"
            let suffix = draft.variant == .dub ? "dub" : "audio"
            return "\(base)_\(suffix).\(ext)"
        case .transcript, .subtitle:
            var parts = [base, draft.content.rawValue]
            switch draft.variant {
            case .original, .dub:
                break
            case .translation:
                parts.append("translation")
                if let language = draft.targetLanguage, !language.isEmpty {
                    parts.append(WorkbenchLanguageLabel.compact(language))
                }
            case .bilingual:
                parts.append("bilingual")
            }
            return parts.joined(separator: "_") + ".\(draft.format.pathExtension)"
        }
    }

    static func renderText(
        session: WorkbenchSession,
        draft: SessionExportDraft
    ) throws -> String {
        let segments = try segments(for: session, draft: draft)
        guard !segments.isEmpty else {
            throw SessionExportError.emptyContent
        }
        return SessionExportFormatter.render(
            segments: segments,
            format: draft.format,
            variant: draft.variant == .translation && draft.content == .subtitle
                ? .original
                : draft.variant,
            translationOrder: draft.translationOrder,
            includeSpeakers: draft.includeSpeakers,
            includeTimestamps: draft.includeTimestamps,
            stripEdgePunctuation: draft.content == .subtitle
        )
    }

    static func audioURL(
        for session: WorkbenchSession,
        variant: SessionExportVariant
    ) throws -> URL {
        switch variant {
        case .dub:
            guard let url = session.outputURL else { throw SessionExportError.missingAudio }
            return url
        case .original, .translation, .bilingual:
            guard let url = session.sourceURL else { throw SessionExportError.missingAudio }
            return url
        }
    }

    private static func transcriptSegments(
        for session: WorkbenchSession,
        draft: SessionExportDraft
    ) throws -> [SessionExportSegment] {
        let translation = translationTrack(for: session, languageCode: draft.targetLanguage)
        switch draft.variant {
        case .original, .dub:
            let source = sourceTranscriptSegments(session)
            guard !source.isEmpty else { throw SessionExportError.emptyContent }
            return source
        case .translation:
            guard let translation else { throw SessionExportError.missingTranslation }
            let cues = orderedCues(translation.cues)
            guard !cues.isEmpty else { throw SessionExportError.emptyContent }
            return cues.map {
                SessionExportSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text,
                    translationText: nil,
                    speaker: $0.speaker
                )
            }
        case .bilingual:
            let source = sourceTranscriptSegments(session)
            guard !source.isEmpty else { throw SessionExportError.emptyContent }
            guard let translation else { throw SessionExportError.missingTranslation }
            let translatedCues = orderedCues(translation.cues)
            return source.map { segment in
                SessionExportSegment(
                    start: segment.start,
                    end: segment.end,
                    text: segment.text,
                    translationText: matchingTranslation(
                        for: segment.start,
                        end: segment.end,
                        in: translatedCues
                    ),
                    speaker: segment.speaker
                )
            }
        }
    }

    private static func subtitleSegments(
        for session: WorkbenchSession,
        draft: SessionExportDraft
    ) throws -> [SessionExportSegment] {
        let sourceTrack = session.subtitleTrack ?? session.dubSubtitleTrack
        switch draft.variant {
        case .original, .dub:
            guard let sourceTrack else { throw SessionExportError.emptyContent }
            let cues = orderedCues(sourceTrack.cues)
            guard !cues.isEmpty else { throw SessionExportError.emptyContent }
            return cues.map {
                SessionExportSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text,
                    translationText: nil,
                    speaker: $0.speaker
                )
            }
        case .translation:
            guard let translation = translationTrack(for: session, languageCode: draft.targetLanguage)
            else { throw SessionExportError.missingTranslation }
            let cues = orderedCues(translation.cues)
            guard !cues.isEmpty else { throw SessionExportError.emptyContent }
            return cues.map {
                SessionExportSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text,
                    translationText: nil,
                    speaker: $0.speaker
                )
            }
        case .bilingual:
            guard let sourceTrack else { throw SessionExportError.emptyContent }
            guard let translation = translationTrack(for: session, languageCode: draft.targetLanguage)
            else { throw SessionExportError.missingTranslation }
            let sourceCues = orderedCues(sourceTrack.cues)
            let translatedCues = orderedCues(translation.cues)
            guard !sourceCues.isEmpty else { throw SessionExportError.emptyContent }
            return sourceCues.map { cue in
                let translated = translatedCues.first(where: {
                    $0.sourceIDs.contains(cue.id) || $0.id == cue.id
                })?.text ?? matchingTranslation(for: cue.start, end: cue.end, in: translatedCues)
                return SessionExportSegment(
                    start: cue.start,
                    end: cue.end,
                    text: cue.text,
                    translationText: translated,
                    speaker: cue.speaker
                )
            }
        }
    }

    private static func sourceTranscriptSegments(_ session: WorkbenchSession) -> [SessionExportSegment] {
        if let transcript = session.transcript {
            let display = transcript.segments.isEmpty
                ? transcript.aggregatingSegments()
                : transcript
            if !display.segments.isEmpty {
                return display.segments
                    .sorted { lhs, rhs in
                        if lhs.start == rhs.start { return lhs.end < rhs.end }
                        return lhs.start < rhs.start
                    }
                    .map {
                        SessionExportSegment(
                            start: $0.start,
                            end: $0.end,
                            text: $0.text,
                            translationText: nil,
                            speaker: $0.speaker
                        )
                    }
            }
        }
        if !session.dubSegments.isEmpty {
            return session.dubSegments
                .sorted { lhs, rhs in
                    if lhs.start == rhs.start { return lhs.index < rhs.index }
                    return lhs.start < rhs.start
                }
                .map {
                    SessionExportSegment(
                        start: $0.start,
                        end: $0.end,
                        text: $0.text,
                        translationText: nil,
                        speaker: $0.speaker
                    )
                }
        }
        return []
    }

    private static func translationTrack(
        for session: WorkbenchSession,
        languageCode: String?
    ) -> SubtitleTrack? {
        if let languageCode {
            return session.translationTracks.first {
                $0.languageCode.caseInsensitiveCompare(languageCode) == .orderedSame
            }?.track
        }
        return session.translationTracks.first?.track
    }

    private static func orderedCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.id < rhs.id }
            return lhs.start < rhs.start
        }
    }

    private static func matchingTranslation(
        for start: Double,
        end: Double,
        in cues: [SubtitleCue]
    ) -> String? {
        let midpoint = start + max(0, (end - start) / 2)
        if let exact = cues.first(where: { $0.start <= midpoint && midpoint < $0.end }) {
            return exact.text
        }
        return cues.max(by: { lhs, rhs in
            overlap(start: start, end: end, cue: lhs) < overlap(start: start, end: end, cue: rhs)
        }).flatMap { overlap(start: start, end: end, cue: $0) > 0 ? $0.text : nil }
    }

    private static func overlap(start: Double, end: Double, cue: SubtitleCue) -> Double {
        max(0, min(end, cue.end) - max(start, cue.start))
    }

    private static func sanitizeFilename(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: " +", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "session" : String(collapsed.prefix(80))
    }
}

enum SessionExportError: LocalizedError, Equatable {
    case emptyContent
    case missingTranslation
    case missingAudio
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            "Nothing is available to export for the current selection."
        case .missingTranslation:
            "No translation track is available for this export."
        case .missingAudio:
            "No audio file is available for this export."
        case .cancelled:
            nil
        }
    }
}

@MainActor
enum SessionExportRunner {
    @discardableResult
    static func run(
        session: WorkbenchSession,
        draft: SessionExportDraft
    ) async throws -> Bool {
        var normalized = draft
        let availability = SessionExportAvailability.from(session)
        normalized.normalize(against: availability)

        switch normalized.content {
        case .audio:
            try await exportAudio(session: session, draft: normalized)
        case .transcript, .subtitle:
            let text = try SessionExportBuilder.renderText(session: session, draft: normalized)
            switch normalized.action {
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                WorkbenchTipCenter.shared.show(
                    "Copied \(normalized.format.title) to the clipboard.",
                    kind: .success,
                    id: "session.export.copied.\(session.id.uuidString)"
                )
            case .download:
                try await saveText(text, session: session, draft: normalized)
            }
        }
        return true
    }

    private static func exportAudio(
        session: WorkbenchSession,
        draft: SessionExportDraft
    ) async throws {
        let sourceURL = try SessionExportBuilder.audioURL(for: session, variant: draft.variant)
        let filename = SessionExportBuilder.suggestedFilename(
            session: session,
            draft: draft,
            audioURL: sourceURL
        )
        guard let destination = await presentSavePanel(
            filename: filename,
            contentType: UTType(filenameExtension: sourceURL.pathExtension) ?? .audio
        ) else {
            throw SessionExportError.cancelled
        }
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: sourceURL, to: destination)
        }.value
        WorkbenchTipCenter.shared.show(
            "Saved \(filename).",
            kind: .success,
            id: "session.export.saved.\(session.id.uuidString)"
        )
    }

    private static func saveText(
        _ text: String,
        session: WorkbenchSession,
        draft: SessionExportDraft
    ) async throws {
        let filename = SessionExportBuilder.suggestedFilename(session: session, draft: draft)
        guard let destination = await presentSavePanel(
            filename: filename,
            contentType: draft.format.contentType
        ) else {
            throw SessionExportError.cancelled
        }
        let data = Data(text.utf8)
        try await Task.detached(priority: .userInitiated) {
            try FileIO.writeData(data, to: destination)
        }.value
        WorkbenchTipCenter.shared.show(
            "Saved \(filename).",
            kind: .success,
            id: "session.export.saved.\(session.id.uuidString)"
        )
    }

    private static func presentSavePanel(
        filename: String,
        contentType: UTType
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [contentType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = filename
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
