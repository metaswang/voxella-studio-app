import AVFoundation
import Foundation
import Speech

enum TranscriptionProvider: String, CaseIterable, Sendable, Codable {
    case local
    case cloud

    var label: String {
        switch self {
        case .local: L10n.key("Local")
        case .cloud: L10n.key("Cloud")
        }
    }
}

enum SpeakerBoundary: String, Sendable, Codable {
    case none
    case soft
    case hard
}

struct TranscriptionWord: Sendable, Codable {
    let text: String
    let start: Double?
    let end: Double?
    let speaker: String?
    let speakerConfidence: Double?
    let speakerBoundary: SpeakerBoundary

    init(
        text: String,
        start: Double?,
        end: Double?,
        speaker: String? = nil,
        speakerConfidence: Double? = nil,
        speakerBoundary: SpeakerBoundary = .none
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.speakerConfidence = speakerConfidence
        self.speakerBoundary = speakerBoundary
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case speaker
        case speakerConfidence
        case speakerBoundary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decodeIfPresent(Double.self, forKey: .start)
        end = try container.decodeIfPresent(Double.self, forKey: .end)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        speakerConfidence = try container.decodeIfPresent(Double.self, forKey: .speakerConfidence)
        speakerBoundary = try container.decodeIfPresent(SpeakerBoundary.self, forKey: .speakerBoundary) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(start, forKey: .start)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encodeIfPresent(speaker, forKey: .speaker)
        try container.encodeIfPresent(speakerConfidence, forKey: .speakerConfidence)
        try container.encode(speakerBoundary, forKey: .speakerBoundary)
    }
}

struct TranscriptionSegment: Sendable, Codable {
    let text: String
    let start: Double
    let end: Double
    let speaker: String?
    let speakerBoundary: SpeakerBoundary

    init(
        text: String,
        start: Double,
        end: Double,
        speaker: String? = nil,
        speakerBoundary: SpeakerBoundary = .none
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
        self.speakerBoundary = speakerBoundary
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case speaker
        case speakerBoundary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        speakerBoundary = try container.decodeIfPresent(SpeakerBoundary.self, forKey: .speakerBoundary) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encodeIfPresent(speaker, forKey: .speaker)
        try container.encode(speakerBoundary, forKey: .speakerBoundary)
    }
}

struct TranscriptionResult: Sendable, Codable {
    let text: String
    let language: String?
    let words: [TranscriptionWord]
    let segments: [TranscriptionSegment]

    /// Shifts all timestamps back into source time after transcribing an extracted range
    func offsetting(by offset: Double) -> TranscriptionResult {
        guard offset != 0 else { return self }
        return TranscriptionResult(
            text: text,
            language: language,
            words: words.map {
                TranscriptionWord(
                    text: $0.text,
                    start: $0.start.map { $0 + offset },
                    end: $0.end.map { $0 + offset },
                    speaker: $0.speaker,
                    speakerConfidence: $0.speakerConfidence,
                    speakerBoundary: $0.speakerBoundary
                )
            },
            segments: segments.map {
                TranscriptionSegment(
                    text: $0.text,
                    start: $0.start + offset,
                    end: $0.end + offset,
                    speaker: $0.speaker,
                    speakerBoundary: $0.speakerBoundary
                )
            }
        )
    }

    /// Fits aligned timestamps into the exact source span used by the editor.
    /// Media containers and decoded PCM can differ by a few frames; scaling a
    /// small tail drift preserves every word and its relative timing instead of
    /// dropping words whose midpoint falls just beyond the timeline clip.
    func fittingTimestamps(to mediaDuration: Double) -> TranscriptionResult {
        guard mediaDuration.isFinite, mediaDuration > 0 else { return self }
        let timedEnds = words.compactMap(\.end) + segments.map(\.end)
        let sourceEnd = timedEnds.filter(\.isFinite).max() ?? mediaDuration
        let scale = sourceEnd > mediaDuration && sourceEnd > 0
            ? mediaDuration / sourceEnd
            : 1
        let minimumSpan = min(0.02, mediaDuration)
        let latestStart = max(0, mediaDuration - minimumSpan)

        func fit(start rawStart: Double, end rawEnd: Double, after previousStart: Double) -> (Double, Double) {
            var start = min(latestStart, max(previousStart, max(0, rawStart * scale)))
            var end = min(mediaDuration, max(start, rawEnd * scale))
            if end - start < minimumSpan {
                if start + minimumSpan <= mediaDuration {
                    end = start + minimumSpan
                } else {
                    start = max(previousStart, mediaDuration - minimumSpan)
                    end = mediaDuration
                }
            }
            return (start, end)
        }

        var previousWordStart = 0.0
        let fittedWords = words.map { word in
            guard let start = word.start, let end = word.end else { return word }
            let fitted = fit(start: start, end: end, after: previousWordStart)
            previousWordStart = fitted.0
            return TranscriptionWord(
                text: word.text,
                start: fitted.0,
                end: fitted.1,
                speaker: word.speaker,
                speakerConfidence: word.speakerConfidence,
                speakerBoundary: word.speakerBoundary
            )
        }

        var previousSegmentStart = 0.0
        let fittedSegments = segments.map { segment in
            let fitted = fit(start: segment.start, end: segment.end, after: previousSegmentStart)
            previousSegmentStart = fitted.0
            return TranscriptionSegment(
                text: segment.text,
                start: fitted.0,
                end: fitted.1,
                speaker: segment.speaker,
                speakerBoundary: segment.speakerBoundary
            )
        }
        return TranscriptionResult(
            text: text,
            language: language,
            words: fittedWords,
            segments: fittedSegments
        )
    }
}

enum TranscriptSegmenter {
    // Mirrors voxella-worker-audio-postprocess transcript rebuilding. Subtitle
    // cues are indivisible; the duration ceiling is intentionally soft so a
    // tiny trailing cue group can stay attached to the preceding segment.
    static let targetDuration = 60.0
    static let maximumDuration = 60.0
    static let minimumDuration = 45.0

    private static var tailMergeGrace: Double {
        max(5, maximumDuration * 0.1)
    }

    static func aggregate(
        words: [TranscriptionWord],
        language: String? = nil
    ) -> [TranscriptionSegment] {
        let items = words.compactMap { word -> TimedText? in
            guard let start = word.start,
                  let end = word.end,
                  start.isFinite,
                  end.isFinite,
                  end > start else { return nil }
            return TimedText(
                text: word.text,
                start: start,
                end: end,
                speaker: word.speaker,
                speakerBoundary: word.speakerBoundary
            )
        }
        return aggregate(items, language: language)
    }

    static func aggregate(
        segments: [TranscriptionSegment],
        language: String? = nil
    ) -> [TranscriptionSegment] {
        aggregate(segments.compactMap { segment in
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.end > segment.start else { return nil }
            return TimedText(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker,
                speakerBoundary: segment.speakerBoundary
            )
        }, language: language)
    }

    private struct TimedText {
        let text: String
        let start: Double
        let end: Double
        let speaker: String?
        let speakerBoundary: SpeakerBoundary
    }

    private static func aggregate(
        _ items: [TimedText],
        language: String?
    ) -> [TranscriptionSegment] {
        guard !items.isEmpty else { return [] }
        let orderedItems = items.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start {
                return lhs.element.start < rhs.element.start
            }
            if lhs.element.end != rhs.element.end {
                return lhs.element.end < rhs.element.end
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
        var emittedGroups: [[TimedText]] = []
        var buffer: [TimedText] = []

        func emit(_ count: Int) {
            let safeCount = min(max(0, count), buffer.count)
            guard safeCount > 0 else { return }
            emittedGroups.append(Array(buffer.prefix(safeCount)))
            buffer.removeFirst(safeCount)
        }

        var index = 0
        while index < orderedItems.count {
            let item = orderedItems[index]
            guard let previous = buffer.last else {
                buffer.append(item)
                index += 1
                continue
            }

            if isKnownSpeakerChange(
                from: previous.speaker,
                to: item.speaker,
                boundary: item.speakerBoundary
            ) {
                emit(buffer.count)
                continue
            }

            buffer.append(item)
            index += 1
            guard let first = buffer.first, let last = buffer.last else { continue }
            let duration = max(0, last.end - first.start)
            let exceeded = duration > maximumDuration
            guard duration >= minimumDuration || exceeded else { continue }

            var bestCount: Int?
            var bestScore: Double?
            if buffer.count >= 2 {
                for cut in stride(from: buffer.count, through: 2, by: -1) {
                    let cutDuration = max(0, buffer[cut - 1].end - first.start)
                    if !exceeded && cutDuration > maximumDuration { continue }
                    if !exceeded && cutDuration < minimumDuration { break }

                    let punctuationRank = endPunctuationRank(buffer[cut - 1].text)
                    let closeness = -abs(cutDuration - targetDuration)
                    let score = Double(punctuationRank * 1_000) + closeness
                    if bestScore.map({ score > $0 }) ?? true {
                        bestScore = score
                        bestCount = cut
                    }
                }
            }

            emit(bestCount ?? (buffer.count == 1 ? 1 : max(1, buffer.count - 1)))
        }

        emit(buffer.count)

        if emittedGroups.count >= 2,
           let tail = emittedGroups.last,
           let previous = emittedGroups.dropLast().last,
           groupDuration(tail) < minimumDuration,
           groupDuration(previous) + groupDuration(tail) <= maximumDuration + tailMergeGrace,
           speakersAreCompatible(previous, tail) {
            emittedGroups[emittedGroups.count - 2].append(contentsOf: tail)
            emittedGroups.removeLast()
        }

        return emittedGroups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return TranscriptionSegment(
                text: joinedText(group.map(\.text), language: language),
                start: first.start,
                end: last.end,
                speaker: dominantSpeaker(in: group),
                speakerBoundary: first.speakerBoundary
            )
        }
    }

    private static func groupDuration(_ group: [TimedText]) -> Double {
        guard let first = group.first, let last = group.last else { return 0 }
        return max(0, last.end - first.start)
    }

    private static func speakersAreCompatible(_ lhs: [TimedText], _ rhs: [TimedText]) -> Bool {
        guard let left = dominantSpeaker(in: lhs), let right = dominantSpeaker(in: rhs) else {
            return true
        }
        return left == right
    }

    private static func isKnownSpeakerChange(
        from lhs: String?,
        to rhs: String?,
        boundary: SpeakerBoundary
    ) -> Bool {
        guard let lhs = normalizedSpeaker(lhs), let rhs = normalizedSpeaker(rhs) else {
            return false
        }
        guard lhs != rhs else { return false }
        return boundary != .soft
    }

    private static func dominantSpeaker(in group: [TimedText]) -> String? {
        var counts: [String: Int] = [:]
        var firstAppearance: [String: Int] = [:]
        for (index, item) in group.enumerated() {
            guard let speaker = normalizedSpeaker(item.speaker) else { continue }
            counts[speaker, default: 0] += 1
            if firstAppearance[speaker] == nil { firstAppearance[speaker] = index }
        }

        var bestSpeaker: String?
        var bestCount = 0
        var bestIndex = Int.max
        for (speaker, count) in counts {
            let index = firstAppearance[speaker] ?? Int.max
            if count > bestCount || (count == bestCount && index < bestIndex) {
                bestSpeaker = speaker
                bestCount = count
                bestIndex = index
            }
        }
        return bestSpeaker
    }

    private static func endPunctuationRank(_ text: String) -> Int {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return 0 }
        if ".?!。？！".contains(last) { return 3 }
        if ",;:，；：".contains(last) { return 2 }
        return 0
    }

    private static func normalizedSpeaker(_ speaker: String?) -> String? {
        let value = speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func joinedText(_ values: [String], language: String? = nil) -> String {
        normalizeDisplayText(values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " "), language: language)
    }

    static func renderedSubtitleText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let characters = Array(trimmed)
        var suffixStart = characters.count
        while suffixStart > 0, isPunctuationOrSymbol(characters[suffixStart - 1]) {
            suffixStart -= 1
        }
        guard suffixStart < characters.count else { return trimmed }
        let preserved = characters[suffixStart...].filter { "?!？！".contains($0) }
        return String(characters[..<suffixStart]) + String(preserved)
    }

    /// Normalizes text at the display boundary using the same punctuation and
    /// CJK whitespace rules as the postprocess worker.  LLM output can contain
    /// spaces between individual Han/Kana characters even when the source
    /// language does not use word separators; those spaces must not leak into
    /// transcript cards, exported subtitles, or the dub script.
    static func normalizeDisplayText(_ text: String, language: String? = nil) -> String {
        var output = ""
        var pendingWhitespace = false

        for character in text {
            if character.isWhitespace {
                pendingWhitespace = true
                continue
            }

            guard let previous = output.last else {
                output.append(character)
                pendingWhitespace = false
                continue
            }

            if pendingWhitespace,
               !shouldAttachWithoutSpace(
                   previous: previous,
                   current: character,
                   language: language
               ) {
                output.append(" ")
            }
            output.append(character)
            pendingWhitespace = false
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldAttachWithoutSpace(
        previous: Character,
        current: Character,
        language: String?
    ) -> Bool {
        if isCJK(previous) && isCJK(current) { return true }
        // Never leave a space before sentence punctuation.  A space after
        // punctuation is language-dependent: English and other whitespace
        // languages need it, while CJK/no-space languages do not.
        if isSubtitlePunctuation(current) { return true }
        if isSubtitlePunctuation(previous) {
            return languageLikelyHasNoWhitespace(language) || isCJK(current)
        }
        if languageLikelyHasNoWhitespace(language),
           !(isWordLike(previous) && isWordLike(current)) {
            return true
        }
        return false
    }

    private static func languageLikelyHasNoWhitespace(_ language: String?) -> Bool {
        guard let language else { return false }
        let base = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
        return ["zh", "ja", "ko", "th", "lo", "my", "km", "bo"].contains(base)
    }

    private static func isWordLike(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar))
        }
    }

    private static func isSubtitlePunctuation(_ character: Character) -> Bool {
        ",.!?;:，。！？；：、)]}".contains(character)
    }

    private static func isPunctuationOrSymbol(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(Int(scalar.value))
                || (0x3040...0x30FF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }
}

extension TranscriptionResult {
    /// Rebuilds the public `segments[]` payload from the corrected, timed
    /// subtitle cues.  Subtitle cues remain the indivisible source of timing;
    /// this method only joins adjacent cues by speaker and the soft duration
    /// window, matching the worker postprocess contract.
    func aggregatingSegments() -> TranscriptionResult {
        let aggregated = TranscriptSegmenter.aggregate(segments: segments, language: language)
        return TranscriptionResult(
            text: TranscriptSegmenter.normalizeDisplayText(text, language: language),
            language: language,
            words: words,
            segments: aggregated
        )
    }

    func assigningSpeaker(_ speaker: String, from start: Double, to end: Double) -> TranscriptionResult {
        let normalized = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, start.isFinite, end.isFinite, end > start else { return self }
        let updatedWords = words.map { word in
            guard Self.overlaps(start: word.start, end: word.end, rangeStart: start, rangeEnd: end) else {
                return word
            }
            return TranscriptionWord(
                text: word.text,
                start: word.start,
                end: word.end,
                speaker: normalized,
                speakerConfidence: 1,
                speakerBoundary: .none
            )
        }
        let updatedSegments = segments.map { segment in
            guard Self.overlaps(
                start: segment.start,
                end: segment.end,
                rangeStart: start,
                rangeEnd: end
            ) else { return segment }
            return TranscriptionSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speaker: normalized,
                speakerBoundary: .none
            )
        }
        let rebuiltSegments = TranscriptSegmenter.aggregate(words: updatedWords, language: language)
        return TranscriptionResult(
            text: text,
            language: language,
            words: updatedWords,
            segments: rebuiltSegments.isEmpty ? updatedSegments : rebuiltSegments
        )
    }

    func renamingSpeaker(_ current: String, to replacement: String) -> TranscriptionResult {
        let source = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty, source != destination else { return self }
        let updatedWords = words.map { word in
            guard word.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) == source else {
                return word
            }
            return TranscriptionWord(
                text: word.text,
                start: word.start,
                end: word.end,
                speaker: destination,
                speakerConfidence: word.speakerConfidence,
                speakerBoundary: word.speakerBoundary
            )
        }
        let updatedSegments = segments.map { segment in
            guard segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) == source else {
                return segment
            }
            return TranscriptionSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speaker: destination,
                speakerBoundary: segment.speakerBoundary
            )
        }
        let rebuiltSegments = TranscriptSegmenter.aggregate(words: updatedWords, language: language)
        return TranscriptionResult(
            text: text,
            language: language,
            words: updatedWords,
            segments: rebuiltSegments.isEmpty ? updatedSegments : rebuiltSegments
        )
    }

    private static func overlaps(
        start: Double?,
        end: Double?,
        rangeStart: Double,
        rangeEnd: Double
    ) -> Bool {
        guard let start, let end, start.isFinite, end.isFinite else { return false }
        return end > rangeStart && start < rangeEnd
    }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case modelInstallFailed(String)
    case decodeFailed
    case audioExtractionFailed(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "On-device transcription is not available for \(id)."
        case .modelInstallFailed(let reason):
            return "Could not install the on-device speech model: \(reason)"
        case .decodeFailed:
            return "Could not parse transcription result."
        case .audioExtractionFailed(let reason):
            return "Audio extraction failed: \(reason)"
        case .analysisFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}

enum Transcription {
    private static let audioExtractionGate = AsyncSemaphore(value: 2)

    static func transcribeVideoAudio(videoURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        let tempAudioURL = try await extractAudioTrack(from: videoURL, range: sourceRange)
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }
        let result = try await transcribe(fileURL: tempAudioURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
        return result.offsetting(by: sourceRange?.lowerBound ?? 0)
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func bestSupportedLocale(from supported: [Locale]) -> Locale? {
        let candidates = Locale.preferredLanguages.map(Locale.init(identifier:)) + [Locale.current]
        return matchLocale(candidates: candidates, supported: supported)
    }

    static func matchLocale(candidates: [Locale], supported: [Locale]) -> Locale? {
        for candidate in candidates {
            // Strip Unicode extension tags (e.g. -u-rg-zazzzz from en-US-u-rg-zazzzz) before
            // matching — the Speech framework doesn't recognise composite BCP 47 tags.
            let baseId = candidate.identifier(.bcp47).components(separatedBy: "-u-").first
                ?? candidate.identifier
            let base = Locale(identifier: baseId)
            guard let lang = base.language.languageCode?.identifier else { continue }
            let sameLang = supported.filter { $0.language.languageCode?.identifier == lang }
            guard !sameLang.isEmpty else { continue }
            let region = base.region?.identifier
            return sameLang.first { $0.region?.identifier == region } ?? sameLang.first
        }
        return nil
    }

    static func transcribe(fileURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        #if BUNDLED_SPEECH
        if let sourceRange {
            let tempURL = try await extractAudioTrack(from: fileURL, range: sourceRange)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let result = try await LocalSpeechPipeline.shared.transcribe(
                sourceURL: tempURL,
                languageCode: TranscriptionLanguage.identifier(for: preferredLocale),
                speakerCount: nil,
                progress: { _, _ in }
            )
            return result.offsetting(by: sourceRange.lowerBound)
        }
        return try await LocalSpeechPipeline.shared.transcribe(
            sourceURL: fileURL,
            languageCode: TranscriptionLanguage.identifier(for: preferredLocale),
            speakerCount: nil,
            progress: { _, _ in }
        )
        #else
        return try await transcribeWithApple(
            fileURL: fileURL,
            censorProfanity: censorProfanity,
            preferredLocale: preferredLocale,
            sourceRange: sourceRange
        )
        #endif
    }

    private static func transcribeWithApple(fileURL: URL, censorProfanity: Bool = false, preferredLocale: Locale? = nil, sourceRange: ClosedRange<Double>? = nil) async throws -> TranscriptionResult {
        if let sourceRange {
            let tempURL = try await extractAudioTrack(from: fileURL, range: sourceRange)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let result = try await transcribeWithApple(fileURL: tempURL, censorProfanity: censorProfanity, preferredLocale: preferredLocale)
            return result.offsetting(by: sourceRange.lowerBound)
        }

        let supported = await SpeechTranscriber.supportedLocales
        let locale: Locale
        if let preferredLocale, let match = matchLocale(candidates: [preferredLocale], supported: supported) {
            locale = match
        } else if let auto = bestSupportedLocale(from: supported) {
            locale = auto
        } else {
            throw TranscriptionError.unsupportedLocale((preferredLocale ?? Locale.current).identifier(.bcp47))
        }
        Log.transcription.notice(
            "transcribe locale=\(locale.identifier(.bcp47))",
            telemetry: "Transcription started",
            data: [
                "locale": locale.identifier(.bcp47),
                "censorProfanity": censorProfanity,
                "hasPreferredLocale": preferredLocale != nil
            ]
        )

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censorProfanity ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange],
        )

        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcription.notice(
                "install model start locale=\(locale.identifier)",
                telemetry: "Transcription model install started",
                data: ["locale": locale.identifier(.bcp47)]
            )
            do {
                try await install.downloadAndInstall()
            } catch {
                Log.transcription.warning(
                    "install model failed locale=\(locale.identifier) error=\(error.localizedDescription)",
                    telemetry: "Transcription model install failed",
                    data: ["locale": locale.identifier(.bcp47), "error": error.localizedDescription]
                )
                throw TranscriptionError.modelInstallFailed(error.localizedDescription)
            }
            Log.transcription.notice(
                "install model ok locale=\(locale.identifier)",
                telemetry: "Transcription model install finished",
                data: ["locale": locale.identifier(.bcp47)]
            )
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.audioExtractionFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let resultsTask = Task { () throws -> [SpeechTranscriber.Result] in
            var acc: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results { acc.append(result) }
            return acc
        }

        Log.transcription.notice("analyze start file=\(fileURL.lastPathComponent)", telemetry: "Transcription analysis started")
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            Log.transcription.warning(
                "analyze failed error=\(error.localizedDescription)",
                telemetry: "Transcription analysis failed",
                data: ["error": error.localizedDescription]
            )
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }

        let collected: [SpeechTranscriber.Result]
        do {
            collected = try await resultsTask.value
        } catch {
            throw TranscriptionError.analysisFailed(error.localizedDescription)
        }

        let decoded = decodeResults(collected, locale: locale)
        Log.transcription.notice(
            "ok textChars=\(decoded.text.count) words=\(decoded.words.count) lang=\(decoded.language ?? "?")",
            telemetry: "Transcription finished",
            data: [
                "textChars": decoded.text.count,
                "words": decoded.words.count,
                "segments": decoded.segments.count,
                "language": decoded.language ?? "unknown"
            ]
        )
        return decoded
    }

    /// Decode the asset's audio track to a PCM file with AVAssetReader
    static func extractAudioTrack(
        from videoURL: URL,
        range: ClosedRange<Double>? = nil,
        fileExtension: String = "caf"
    ) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxella-stt-\(UUID().uuidString).\(fileExtension)")
        try await audioExtractionGate.wait()
        defer { Task { await audioExtractionGate.signal() } }

        Log.transcription.notice(
            "extract start video=\(videoURL.lastPathComponent)",
            telemetry: "Transcription audio extraction started",
            data: ["hasRange": range != nil, "rangeSeconds": range.map { $0.upperBound - $0.lowerBound } ?? 0]
        )

        var audioFile: AVAudioFile?
        do {
            try await AudioTrackReader.read(from: videoURL, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ], range: range) { pcm in
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: outURL,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try audioFile?.write(from: pcm)
            }
        } catch let error as AudioTrackReader.ReadError {
            throw TranscriptionError.audioExtractionFailed(error.message)
        }

        guard audioFile != nil else {
            throw TranscriptionError.audioExtractionFailed("No audio samples in \(videoURL.lastPathComponent)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        Log.transcription.notice(
            "extract ok bytes=\(bytes) out=\(outURL.lastPathComponent)",
            telemetry: "Transcription audio extraction finished",
            data: ["bytes": bytes, "hasRange": range != nil]
        )
        return outURL
    }

    /// Each `Result` is one endpointed segment; emit it as a TranscriptionSegment
    /// (text + time range) and walk its runs into per-token TranscriptionWords.
    private static func decodeResults(
        _ results: [SpeechTranscriber.Result],
        locale: Locale,
    ) -> TranscriptionResult {
        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        var fullText = ""

        for result in results {
            let attributed = result.text
            fullText += String(attributed.characters)

            let segmentText = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segmentText.isEmpty {
                segments.append(TranscriptionSegment(
                    text: segmentText,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    speaker: nil
                ))
            }

            for run in attributed.runs {
                let runText = String(attributed[run.range].characters)
                let trimmed = runText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let range = run.audioTimeRange
                let start = range.map(\.start.seconds)
                let end = range.map { ($0.start + $0.duration).seconds }
                words.append(TranscriptionWord(text: trimmed, start: start, end: end, speaker: nil))
            }
        }

        return TranscriptionResult(
            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            language: locale.identifier(.bcp47),
            words: words,
            segments: segments,
        )
    }
}
