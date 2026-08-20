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

        let units = lexicalUnits(
            texts: timed.map(\.text),
            starts: timed.map(\.start),
            ends: timed.map(\.end),
            languageCode: languageCode
        )

        var attributed: [TranscriptionWord] = []
        attributed.reserveCapacity(timed.count)
        for unit in units {
            let attribution = timeline.attributionForWord(start: unit.start, end: unit.end)
            let speaker = attribution.map { "Speaker \($0.speakerID + 1)" }
            let confidence = attribution?.confidence
            for index in unit.wordIndices {
                let item = timed[index]
                attributed.append(
                    TranscriptionWord(
                        text: item.text,
                        start: item.start,
                        end: item.end,
                        speaker: speaker,
                        speakerConfidence: confidence
                    )
                )
            }
        }

        return smoothLexicalAssignments(attributed, units: units, policy: policy)
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
        policy: SpeakerDiarizationPolicy
    ) -> [TranscriptionWord] {
        guard units.count >= 3 else {
            return markingSpeakerBoundaries(words, units: units, policy: policy)
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
            guard end >= start, end - start <= policy.shortTurnDuration else { continue }
            for unitIndex in runStart..<runEnd {
                unitSpeakers[unitIndex] = previousSpeaker
            }
        }

        var resolved: [TranscriptionWord] = []
        resolved.reserveCapacity(words.count)
        for (unitIndex, unit) in units.enumerated() {
            let speaker = unitSpeakers[unitIndex]
            let confidence = words[unit.wordIndices.lowerBound].speakerConfidence
            for wordIndex in unit.wordIndices {
                let word = words[wordIndex]
                resolved.append(
                    TranscriptionWord(
                        text: word.text,
                        start: word.start,
                        end: word.end,
                        speaker: speaker,
                        speakerConfidence: confidence
                    )
                )
            }
        }
        return markingSpeakerBoundaries(resolved, units: units, policy: policy)
    }

    private static func markingSpeakerBoundaries(
        _ words: [TranscriptionWord],
        units: [LexicalUnit],
        policy: SpeakerDiarizationPolicy
    ) -> [TranscriptionWord] {
        var boundaryByWordIndex: [Int: SpeakerBoundary] = [:]
        for (unitIndex, unit) in units.enumerated() {
            let wordIndex = unit.wordIndices.lowerBound
            guard unitIndex > 0 else {
                boundaryByWordIndex[wordIndex] = .none
                continue
            }
            let previous = units[unitIndex - 1]
            let previousSpeaker = normalizedSpeaker(words[previous.wordIndices.lowerBound].speaker)
            let currentSpeaker = normalizedSpeaker(words[wordIndex].speaker)
            guard let previousSpeaker, let currentSpeaker, previousSpeaker != currentSpeaker else {
                boundaryByWordIndex[wordIndex] = .none
                continue
            }
            let confidence = min(
                words[wordIndex].speakerConfidence ?? 0,
                words[previous.wordIndices.lowerBound].speakerConfidence ?? 0
            )
            if confidence < policy.softBoundaryConfidence {
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
                speakerBoundary: boundaryByWordIndex[index] ?? .none
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
