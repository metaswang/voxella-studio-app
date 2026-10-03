import Foundation

struct SpeakerBoundaryRefinementDiagnostics: Codable, Equatable, Sendable {
    var candidateCount = 0
    var acceptedCount = 0
    var unresolvedCount = 0
}

/// Rechecks timing near speaker changes without rewriting recognized text or
/// forcing a grammatical sentence to belong to a single speaker.
enum SpeakerBoundaryRefiner {
    struct Timing: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    struct Window: Equatable, Sendable {
        let wordIndices: Range<Int>
        let start: Double
        let end: Double
        let text: String
    }

    struct Result: Sendable {
        let words: [TranscriptionWord]
        let diagnostics: SpeakerBoundaryRefinementDiagnostics
    }

    static func candidates(words: [TranscriptionWord], timeline: SpeakerActivityTimeline,
                           languageCode: String?) -> [Window] {
        guard words.count > 1, timeline.speakerCount > 1,
              words.allSatisfy({ $0.start?.isFinite == true && $0.end?.isFinite == true }) else { return [] }
        let units = LexicalSpeakerResolver.lexicalUnits(
            texts: words.map(\.text), starts: words.map { $0.start! }, ends: words.map { $0.end! },
            languageCode: languageCode
        )
        let shortDuration = 2 * (timeline.frameDuration > 0 ? timeline.frameDuration : 0.08) + 0.00001
        var windows: [Window] = []
        for index in units.indices.dropFirst() {
            let left = units[index - 1], right = units[index]
            let leftSpeaker = words[left.wordIndices.lowerBound].speaker
            let rightSpeaker = words[right.wordIndices.lowerBound].speaker
            guard leftSpeaker != rightSpeaker else { continue }
            let adjacent = left.wordIndices.lowerBound..<right.wordIndices.upperBound
            let short = min(left.end - left.start, right.end - right.start) <= shortDuration
            let uncertain = adjacent.contains {
                words[$0].timingQuality != .aligned || (words[$0].speakerConfidence ?? 0) < 0.84
            }
            // Look for up to two words left over after the previous sentence.
            let fragment = (max(0, index - 3)..<max(0, index - 1)).contains { previous in
                let text = units[previous].text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.last.map { ".!?。！？".contains($0) } == true
                    && left.end - units[previous + 1].start <= 0.6
            }
            guard short || uncertain || fragment else { continue }
            let boundary = (left.end + right.start) / 2
            let start = max(0, boundary - 2), end = min(timeline.audioDuration, boundary + 2)
            guard let first = words.firstIndex(where: { $0.end! > start }),
                  let last = words.lastIndex(where: { $0.start! < end }) else { continue }
            guard first <= last else { continue }
            let range = first..<(last + 1)
            // Include complete context words; never clip a context word's audio.
            let window = Window(wordIndices: range, start: max(0, min(start, words[first].start!) - 0.6),
                                end: min(timeline.audioDuration, max(end, words[last].end!) + 0.6),
                                text: TranscriptSegmenter.joinedText(range.map { words[$0].text }, language: languageCode))
            if let previous = windows.last, previous.wordIndices.overlaps(range),
               window.end - previous.start <= 12 {
                let merged = previous.wordIndices.lowerBound..<max(previous.wordIndices.upperBound, range.upperBound)
                windows[windows.count - 1] = Window(
                    wordIndices: merged, start: previous.start, end: max(previous.end, window.end),
                    text: TranscriptSegmenter.joinedText(merged.map { words[$0].text }, language: languageCode)
                )
            } else {
                windows.append(window)
            }
        }
        return windows
    }

    static func refine(
        words: [TranscriptionWord], timeline: SpeakerActivityTimeline, languageCode: String?,
        policy: SpeakerDiarizationPolicy = .standard(requestedSpeakerCount: nil),
        isolation: isolated (any Actor)? = #isolation,
        align: (Window) async throws -> [Timing]
    ) async throws -> Result {
        let windows = candidates(words: words, timeline: timeline, languageCode: languageCode)
        var updated = words
        var acceptedRanges: [Range<Int>] = []
        var unresolvedRanges: [Range<Int>] = []
        var diagnostics = SpeakerBoundaryRefinementDiagnostics(candidateCount: windows.count)
        for window in windows {
            try Task.checkCancellation()
            guard window.end - window.start <= 12 else {
                diagnostics.unresolvedCount += 1
                unresolvedRanges.append(window.wordIndices)
                continue
            }
            do {
                let local = try await align(window)
                try Task.checkCancellation()
                guard let remapped = remap(local, onto: Array(words[window.wordIndices]), window: window),
                      let accepted = accepting(remapped, window: window, original: updated,
                                               timeline: timeline, languageCode: languageCode, policy: policy) else {
                    diagnostics.unresolvedCount += 1
                    unresolvedRanges.append(window.wordIndices)
                    continue
                }
                updated.replaceSubrange(window.wordIndices, with: accepted)
                diagnostics.acceptedCount += 1
                acceptedRanges.append(window.wordIndices)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                diagnostics.unresolvedCount += 1
                unresolvedRanges.append(window.wordIndices)
            }
        }
        // Recompute boundaries with full context after each accepted timing patch.
        if diagnostics.acceptedCount > 0 {
            let marked = LexicalSpeakerResolver.markingBoundaries(updated, timeline: timeline,
                                                                  languageCode: languageCode, policy: policy)
            updated = updated.indices.map { index in
                let affected = acceptedRanges.contains { $0.contains(index) || $0.upperBound == index }
                let unresolved = unresolvedRanges.contains { $0.contains(index) }
                return affected && !unresolved ? marked[index] : updated[index]
            }
        }
        return Result(words: updated, diagnostics: diagnostics)
    }

    /// Aligner tokenization can differ (e.g. Chinese characters or apostrophes).
    /// Map exact lexical content back onto the original authored words.
    static func remap(_ timings: [Timing], onto words: [TranscriptionWord], window: Window) -> [TranscriptionWord]? {
        var previousStart = window.start - 0.001
        for (index, timing) in timings.enumerated() {
            if index > 0, timing.start == timings[index - 1].start,
               timing.end == timings[index - 1].end { return nil }
            guard timing.start.isFinite, timing.end.isFinite, timing.end > timing.start,
                  timing.start >= window.start - 0.001, timing.end <= window.end + 0.001,
                  timing.start >= previousStart else { return nil }
            previousStart = timing.start
        }
        let pieces = timings.map { lexicalContent($0.text) }
        let originals = words.map { lexicalContent($0.text) }
        guard !timings.isEmpty, pieces.joined() == originals.joined(), !pieces.joined().isEmpty else { return nil }
        var ranges: [Range<Int>] = []
        var offset = 0
        for piece in pieces {
            ranges.append(offset..<(offset + piece.count))
            offset += piece.count
        }
        offset = 0
        var result: [TranscriptionWord] = []
        for (index, word) in words.enumerated() {
            let content = originals[index]
            guard !content.isEmpty else { result.append(word); continue }
            let range = offset..<(offset + content.count)
            offset += content.count
            guard let first = ranges.firstIndex(where: { $0.overlaps(range) }),
                  let last = ranges.lastIndex(where: { $0.overlaps(range) }) else { return nil }
            result.append(.init(text: word.text, start: max(window.start, timings[first].start),
                                end: min(window.end, timings[last].end),
                                speaker: word.speaker, speakerConfidence: word.speakerConfidence,
                                speakerBoundary: word.speakerBoundary, timingQuality: .aligned))
        }
        return result
    }

    private static func accepting(_ remapped: [TranscriptionWord], window: Window,
                                  original: [TranscriptionWord], timeline: SpeakerActivityTimeline,
                                  languageCode: String?, policy: SpeakerDiarizationPolicy) -> [TranscriptionWord]? {
        let first = window.wordIndices.lowerBound, last = window.wordIndices.upperBound
        let tolerance = max(0.08, timeline.frameDuration)
        guard let start = remapped.first?.start, let end = remapped.last?.end,
              first == 0 || start >= (original[first - 1].end ?? start) - tolerance,
              last == original.count || end <= (original[last].start ?? end) + tolerance else { return nil }
        let attributed = LexicalSpeakerResolver.resolving(remapped, timeline: timeline,
                                                          languageCode: languageCode, policy: policy)
        let units = LexicalSpeakerResolver.lexicalUnits(
            texts: attributed.map(\.text), starts: attributed.map { $0.start! },
            ends: attributed.map { $0.end! }, languageCode: languageCode
        )
        // Every re-aligned lexical unit needs real, unambiguous acoustic support.
        // Otherwise the entire patch stays unresolved, including its timings.
        for unit in units {
            guard let evidence = timeline.attributionForWord(start: unit.start, end: unit.end),
                  evidence.confidence >= policy.hardBoundaryConfidence,
                  evidence.absoluteProbability >= Double(policy.onsetThreshold),
                  evidence.margin >= 0.2,
                  evidence.supportDuration >= min(tolerance, unit.end - unit.start) - 0.00001 else { return nil }
        }
        return attributed
    }

    private static func lexicalContent(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }
}
