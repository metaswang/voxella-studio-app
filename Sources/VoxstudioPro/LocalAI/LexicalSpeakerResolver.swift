import Foundation
import NaturalLanguage

#if BUNDLED_SPEECH
import AudioCommon
#endif

/// Attributes speakers at lexical-unit granularity, then broadcasts to aligned units.
///
/// QWen3 Chinese alignment emits one unit per Han character. Per-character
/// diarization attribution can place a hard boundary inside a compound such as
/// "费力". This resolver keeps those alignment units, but decides speaker on
/// NLTokenizer lexical spans so Stage1/segmenter never hard-cut inside a word.
enum LexicalSpeakerResolver {
    struct LexicalUnit: Equatable, Sendable {
        var wordIndices: Range<Int>
        var text: String
        var start: Double
        var end: Double
    }

    #if BUNDLED_SPEECH
    static func assignSpeakers(
        to aligned: [AlignedWord],
        timeline: SpeakerActivityTimeline,
        audioDuration: Double,
        languageCode: String?,
        policy: SpeakerDiarizationPolicy = .standard(requestedSpeakerCount: nil)
    ) -> [TranscriptionWord] {
        let timed = normalizedTimings(for: aligned, audioDuration: audioDuration)
        guard !timed.isEmpty else { return [] }

        let words = timed.enumerated().map { index, item in
            TranscriptionWord(text: item.text, start: item.start, end: aligned[index].endTime > aligned[index].startTime ? item.end : item.start,
                              timingQuality: aligned[index].endTime > aligned[index].startTime ? .aligned : .estimated)
        }
        return resolving(words, timeline: timeline, languageCode: languageCode, policy: policy)
    }

    static func wordsWithoutSpeakerAttribution(
        to aligned: [AlignedWord],
        audioDuration: Double
    ) -> [TranscriptionWord] {
        normalizedTimings(for: aligned, audioDuration: audioDuration).map {
            TranscriptionWord(
                text: $0.text,
                start: $0.start,
                end: $0.end
            )
        }
    }

    private static func normalizedTimings(
        for aligned: [AlignedWord],
        audioDuration: Double
    ) -> [(text: String, start: Double, end: Double)] {
        var previousStart = 0.0
        return aligned.map { word in
            let timing = LocalSpeechPipeline.normalizedWordTiming(
                start: Double(word.startTime),
                end: Double(word.endTime),
                previousStart: previousStart,
                audioDuration: audioDuration
            )
            previousStart = timing.start
            return (word.text, timing.start, timing.end)
        }
    }
    #endif

    /// Shared by native ASR, forced alignment and local boundary replays.
    static func resolving(
        _ words: [TranscriptionWord],
        timeline: SpeakerActivityTimeline,
        languageCode: String?,
        policy: SpeakerDiarizationPolicy = .standard(requestedSpeakerCount: nil)
    ) -> [TranscriptionWord] {
        guard words.allSatisfy({ $0.start?.isFinite == true && $0.end?.isFinite == true }) else { return words }
        let units = lexicalUnits(texts: words.map(\.text), starts: words.map { $0.start! },
                                 ends: words.map { $0.end! }, languageCode: languageCode)
        var attributed = words
        for unit in units {
            // Keep the best supported identity on release tails; absolute evidence
            // controls boundary strength and refinement acceptance, not label erasure.
            let evidence = timeline.attributionForWord(start: unit.start, end: unit.end)
            for index in unit.wordIndices {
                let word = words[index]
                attributed[index] = TranscriptionWord(
                    text: word.text, start: word.start, end: word.end,
                    speaker: evidence.map { "Speaker \($0.speakerID + 1)" },
                    speakerConfidence: evidence?.confidence, timingQuality: word.timingQuality
                )
            }
        }
        return smoothLexicalAssignments(attributed, units: units, policy: policy, timeline: timeline)
    }

    static func markingBoundaries(
        _ words: [TranscriptionWord], timeline: SpeakerActivityTimeline, languageCode: String?,
        policy: SpeakerDiarizationPolicy = .standard(requestedSpeakerCount: nil)
    ) -> [TranscriptionWord] {
        guard words.allSatisfy({ $0.start?.isFinite == true && $0.end?.isFinite == true }) else { return words }
        let units = lexicalUnits(texts: words.map(\.text), starts: words.map { $0.start! },
                                 ends: words.map { $0.end! }, languageCode: languageCode)
        return markingSpeakerBoundaries(words, units: units, policy: policy, timeline: timeline)
    }

    static func lexicalUnits(
        texts: [String],
        starts: [Double],
        ends: [Double],
        languageCode: String?
    ) -> [LexicalUnit] {
        precondition(texts.count == starts.count && texts.count == ends.count)
        guard !texts.isEmpty else { return [] }

        if prefersCharacterAlignedUnits(languageCode: languageCode, texts: texts) {
            return chineseLexicalUnits(texts: texts, starts: starts, ends: ends, languageCode: languageCode)
        }

        return texts.indices.map { index in
            LexicalUnit(
                wordIndices: index..<(index + 1),
                text: texts[index],
                start: starts[index],
                end: max(ends[index], starts[index])
            )
        }
    }

    private static func chineseLexicalUnits(
        texts: [String],
        starts: [Double],
        ends: [Double],
        languageCode: String?
    ) -> [LexicalUnit] {
        let pieces = texts.map { $0.filter { !$0.isWhitespace } }
        let joined = pieces.joined()
        guard !joined.isEmpty else {
            return texts.indices.map {
                LexicalUnit(
                    wordIndices: $0..<($0 + 1),
                    text: texts[$0],
                    start: starts[$0],
                    end: max(ends[$0], starts[$0])
                )
            }
        }

        var characterToWord: [Int] = []
        characterToWord.reserveCapacity(joined.count)
        for (wordIndex, piece) in pieces.enumerated() {
            for _ in piece {
                characterToWord.append(wordIndex)
            }
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = joined
        if let language = nlLanguage(from: languageCode) {
            tokenizer.setLanguage(language)
        }

        var covered = Set<Int>()
        var units: [LexicalUnit] = []
        tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
            let lower = joined.distance(from: joined.startIndex, to: range.lowerBound)
            let upper = joined.distance(from: joined.startIndex, to: range.upperBound)
            guard upper > lower, lower >= 0, upper <= characterToWord.count else { return true }

            var indices: [Int] = []
            for characterIndex in lower..<upper {
                let wordIndex = characterToWord[characterIndex]
                if indices.last != wordIndex {
                    indices.append(wordIndex)
                }
                covered.insert(wordIndex)
            }
            guard let first = indices.first, let last = indices.last else { return true }
            units.append(
                LexicalUnit(
                    wordIndices: first..<(last + 1),
                    text: texts[first...last].joined(),
                    start: starts[first],
                    end: max(ends[last], starts[first])
                )
            )
            return true
        }

        for wordIndex in texts.indices where !covered.contains(wordIndex) {
            units.append(
                LexicalUnit(
                    wordIndices: wordIndex..<(wordIndex + 1),
                    text: texts[wordIndex],
                    start: starts[wordIndex],
                    end: max(ends[wordIndex], starts[wordIndex])
                )
            )
        }

        return units.sorted { $0.wordIndices.lowerBound < $1.wordIndices.lowerBound }
    }

    private static func smoothLexicalAssignments(
        _ words: [TranscriptionWord],
        units: [LexicalUnit],
        policy: SpeakerDiarizationPolicy,
        timeline: SpeakerActivityTimeline
    ) -> [TranscriptionWord] {
        guard units.count >= 3 else {
            return markingSpeakerBoundaries(words, units: units, policy: policy, timeline: timeline)
        }

        var unitSpeakers: [String?] = units.map { unit in
            normalizedSpeaker(words[unit.wordIndices.lowerBound].speaker)
        }

        var index = 0
        while index < units.count {
            let runStart = index
            let speaker = unitSpeakers[index]
            index += 1
            while index < units.count, unitSpeakers[index] == speaker {
                index += 1
            }
            let runEnd = index
            guard runStart > 0,
                  runEnd < units.count,
                  runEnd - runStart <= max(1, policy.maximumShortTurnWords),
                  let previousSpeaker = unitSpeakers[runStart - 1],
                  let followingSpeaker = unitSpeakers[runEnd],
                  previousSpeaker == followingSpeaker,
                  let speaker,
                  speaker != previousSpeaker else {
                continue
            }

            let start = units[runStart].start
            let end = units[runEnd - 1].end
            guard end > start, end - start <= policy.shortTurnDuration else { continue }
            // A brief real reply must survive even when surrounded by the same host.
            guard (runStart..<runEnd).allSatisfy({ unitIndex in
                let unit = units[unitIndex]
                guard let evidence = timeline.attributionForWord(start: unit.start, end: unit.end) else { return false }
                return evidence.confidence < policy.softBoundaryConfidence
                    && evidence.absoluteProbability < Double(policy.onsetThreshold)
            }) else { continue }
            for unitIndex in runStart..<runEnd {
                unitSpeakers[unitIndex] = previousSpeaker
            }
        }

        var resolved: [TranscriptionWord] = []
        resolved.reserveCapacity(words.count)
        for (unitIndex, unit) in units.enumerated() {
            let speaker = unitSpeakers[unitIndex]
            let confidence = speaker == words[unit.wordIndices.lowerBound].speaker
                ? words[unit.wordIndices.lowerBound].speakerConfidence : nil
            for wordIndex in unit.wordIndices {
                let word = words[wordIndex]
                resolved.append(
                    TranscriptionWord(
                        text: word.text,
                        start: word.start,
                        end: word.end,
                        speaker: speaker,
                        speakerConfidence: confidence, timingQuality: word.timingQuality
                    )
                )
            }
        }
        return markingSpeakerBoundaries(resolved, units: units, policy: policy, timeline: timeline)
    }

    private static func markingSpeakerBoundaries(
        _ words: [TranscriptionWord],
        units: [LexicalUnit],
        policy: SpeakerDiarizationPolicy,
        timeline: SpeakerActivityTimeline
    ) -> [TranscriptionWord] {
        var boundaryByWordIndex: [Int: SpeakerBoundary] = [:]
        for (unitIndex, unit) in units.enumerated() {
            let wordIndex = unit.wordIndices.lowerBound
            guard unitIndex > 0 else {
                boundaryByWordIndex[wordIndex] = SpeakerBoundary.none
                continue
            }
            let previous = units[unitIndex - 1]
            let previousSpeaker = normalizedSpeaker(words[previous.wordIndices.lowerBound].speaker)
            let currentSpeaker = normalizedSpeaker(words[wordIndex].speaker)
            guard let previousSpeaker, let currentSpeaker, previousSpeaker != currentSpeaker else {
                boundaryByWordIndex[wordIndex] = SpeakerBoundary.none
                continue
            }
            let confidence = min(
                words[wordIndex].speakerConfidence ?? 0,
                words[previous.wordIndices.lowerBound].speakerConfidence ?? 0
            )
            let evidence = timeline.attributionForWord(start: unit.start, end: unit.end)
            // A fading outgoing word must not cancel a clear incoming speaker.
            let hasAbsoluteSupport = (evidence?.absoluteProbability ?? 0) >= Double(policy.onsetThreshold)
                && (evidence?.margin ?? 0) >= 0.2
            if !hasAbsoluteSupport || confidence < policy.softBoundaryConfidence {
                boundaryByWordIndex[wordIndex] = .soft
            } else {
                boundaryByWordIndex[wordIndex] = confidence >= policy.hardBoundaryConfidence ? .hard : .soft
            }
        }

        return words.enumerated().map { index, word in
            TranscriptionWord(
                text: word.text,
                start: word.start,
                end: word.end,
                speaker: word.speaker,
                speakerConfidence: word.speakerConfidence,
                speakerBoundary: boundaryByWordIndex[index] ?? .none, timingQuality: word.timingQuality
            )
        }
    }

    private static func prefersCharacterAlignedUnits(languageCode: String?, texts: [String]) -> Bool {
        let base = languageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init)
        if let base, ["zh", "yue"].contains(base) {
            return true
        }
        let compact = texts.joined().filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return false }
        let hanCount = compact.unicodeScalars.filter(isHanIdeograph).count
        return Double(hanCount) / Double(compact.count) >= 0.25
    }

    private static func nlLanguage(from languageCode: String?) -> NLLanguage? {
        guard let languageCode else { return nil }
        let base = languageCode.lowercased().split(separator: "-").first.map(String.init) ?? languageCode
        switch base {
        case "zh", "yue": return .simplifiedChinese
        case "ja": return .japanese
        case "ko": return .korean
        case "en": return .english
        default: return NLLanguage(rawValue: base)
        }
    }

    private static func normalizedSpeaker(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func isHanIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
            || (0xF900...0xFAFF).contains(value)
    }
}
