import AppKit
import CoreText
import Foundation
import NaturalLanguage

/// The same cue solver is used for source, translated and offline captions.
/// Offsets are UTF-16 at extended-grapheme boundaries, never tokenizer-joined text.
enum ElasticSubtitleSegmenter {
    static let processingVersion = "elastic-v1"

    struct LayoutProfile: Sendable {
        var style: TextStyle = EditorViewModel.CaptionRequest.defaultLocalStyle
        var canvasWidth: Int = 1920
        var canvasHeight: Int = 1080
        var maximumLines: Int = 2

        func measure(_ text: String) -> Measurement {
            let visual = style.scaledVisualStyle
            let fontSize = max(1, visual.fontSize * Double(canvasHeight) / 1080)
            let attributes = visual.attributes(size: CGFloat(fontSize), includeColor: false)
            let string = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(string)
            let em = CTLineGetTypographicBounds(line, nil, nil, nil) / fontSize
            // Use the renderer's decoration slack and the same 90% safe region.
            let decorated = TextLayout.naturalSize(content: "", style: style, maxWidth: .greatestFiniteMagnitude,
                                                  canvasHeight: CGFloat(canvasHeight))
            let width = max(1, Double(canvasWidth) * 0.9 - Double(decorated.width))
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            var offset = 0
            var breaks: [Int] = []
            var lineCount = 0
            while offset < string.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, offset, width)
                guard count > 0 else { return Measurement(breaks: breaks, em: em, fits: false) }
                offset += count
                lineCount += 1
                if offset < string.length { breaks.append(offset) }
                if lineCount > maximumLines { return Measurement(breaks: [], em: em, fits: false) }
            }
            return Measurement(breaks: breaks, em: em, fits: true)
        }
    }

    struct Measurement: Sendable {
        var breaks: [Int]
        var em: Double
        var fits: Bool
    }

    struct Anchor: Sendable {
        var range: NSRange
        var start: Double
        var end: Double
        var quality: WordTimingQuality = .unknown
        var hardBefore = false
    }

    struct Input: Sendable {
        var text: String
        var languageCode: String? = nil
        var proposedLines: [String] = []
        var protectedSpans: [String] = []
        var anchors: [Anchor] = []
        var start: Double? = nil
        var end: Double? = nil
        var layout = LayoutProfile()
        /// Explicit user limits remain supported; automatic mode has no character cap.
        var maximumCharacters: Int? = nil
        var maximumWords: Int? = nil
        var policy = SubtitleBoundaryOptimizer.Policy()
    }

    struct Cue: Sendable {
        var range: NSRange
        var text: String
        var displayLineBreaks: [Int]
        var layoutOverflow: Bool
    }

    struct Result: Sendable {
        var cues: [Cue]
        var projection: SubtitleBoundaryOptimizer.Projection
        var lines: [String] { cues.map(\.text) }
    }

    private static let terminal = try! NSRegularExpression(pattern: #"\p{STerm}"#)
    private static let punctuation = try! NSRegularExpression(pattern: #"\p{P}"#)
    private static let opening = try! NSRegularExpression(pattern: #"[\p{Ps}\p{Pi}]"#)

    static func isTerminal(_ character: Character) -> Bool { matches(terminal, character) }

    static func hardBoundary(previous: TranscriptionWord?, current: TranscriptionWord) -> Bool {
        guard current.timingQuality != .estimated else { return false }
        if current.speakerBoundary == .hard, (current.speakerConfidence ?? 1) >= 0.9 { return true }
        // Legacy/provided speakers have no diarization confidence; preserve those assignments.
        return current.speakerConfidence == nil && current.speakerBoundary != .soft
            && previous?.speaker != nil && current.speaker != nil && previous?.speaker != current.speaker
    }

    static func anchors(text: String, words: [TranscriptionWord]) -> [Anchor] {
        let source = text as NSString
        var cursor = 0
        var result: [Anchor] = []
        for (index, word) in words.enumerated() {
            guard let a = word.start, let b = word.end, a.isFinite, b.isFinite, b >= a else { continue }
            let match = source.range(of: word.text, options: .literal,
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound else { continue }
            result.append(Anchor(range: match, start: a, end: b, quality: word.timingQuality,
                hardBefore: hardBoundary(previous: index > 0 ? words[index - 1] : nil, current: word)))
            cursor = NSMaxRange(match)
        }
        return result
    }

    /// Preserve chunk interiors; only choose the missing inter-chunk separator.
    static func joinChunks(_ chunks: [String], languageCode: String?) -> String {
        var result = ""
        for chunk in chunks where !chunk.isEmpty {
            if let left = result.last, let right = chunk.first, !left.isWhitespace, !right.isWhitespace {
                let edge = TranscriptSegmenter.joinedText([String(left), String(right)], language: languageCode)
                if edge.hasPrefix(String(left)), edge.hasSuffix(String(right)) {
                    let begin = edge.index(edge.startIndex, offsetBy: 1)
                    let end = edge.index(before: edge.endIndex)
                    result += String(edge[begin..<end])
                } else { result += " " }
            }
            result += chunk
        }
        return result
    }

    static func uniqueProtectedRanges(_ hints: [String], text: String) -> [NSRange] {
        let source = text as NSString
        return hints.compactMap { hint in
            guard !hint.isEmpty else { return nil }
            let first = source.range(of: hint, options: .literal)
            guard first.location != NSNotFound else { return nil }
            let after = NSMaxRange(first)
            if after < source.length,
               source.range(of: hint, options: .literal,
                            range: NSRange(location: after, length: source.length - after)).location != NSNotFound { return nil }
            return first
        }
    }

    static func optimize(_ input: Input, fits: ((String) -> Bool)? = nil) throws -> Result {
        try Task.checkCancellation()
        guard input.policy.isValid else { throw SubtitleBoundaryOptimizer.OptimizationError.invalidPolicy }
        let source = input.text as NSString
        let chars = Array(input.text)
        let projection = SubtitleBoundaryOptimizer.projectBoundaries(sourceText: input.text, proposedLines: input.proposedLines)
        guard !chars.isEmpty else { return Result(cues: [], projection: projection) }
        var offsets = [0]
        for char in chars { offsets.append(offsets.last! + String(char).utf16.count) }
        let indexAtOffset = Dictionary(uniqueKeysWithValues: offsets.enumerated().map { ($0.element, $0.offset) })
        var next = Array(0...chars.count)
        for index in stride(from: chars.count - 1, through: 0, by: -1) where chars[index].isWhitespace { next[index] = next[index + 1] }
        var trim = [0]
        for (index, char) in chars.enumerated() { trim.append(char.isWhitespace ? trim.last! : index + 1) }
        var natural: Set<Int> = [0, chars.count]
        var wordEnds = Array(repeating: 0, count: chars.count + 1)
        var insideWord = Array(repeating: false, count: chars.count + 1)
        var sentenceEnds: Set<Int> = []
        for unit in [NLTokenUnit.word, .sentence] {
            let tokenizer = NLTokenizer(unit: unit)
            tokenizer.string = input.text
            if let language = input.languageCode?.split(separator: "-").first { tokenizer.setLanguage(NLLanguage(rawValue: String(language))) }
            tokenizer.enumerateTokens(in: input.text.startIndex..<input.text.endIndex) { range, _ in
                if let begin = indexAtOffset[range.lowerBound.utf16Offset(in: input.text)],
                   let end = indexAtOffset[range.upperBound.utf16Offset(in: input.text)] {
                    if unit == .word {
                        wordEnds[end] += 1
                        if end - begin > 1 { for index in (begin + 1)..<end { insideWord[index] = true } }
                    } else { sentenceEnds.insert(trim[end]) }
                }
                for boundary in [range.lowerBound, range.upperBound] {
                    let utf16 = boundary.utf16Offset(in: input.text)
                    if let index = indexAtOffset[utf16] { natural.insert(next[index]) }
                }
                return true
            }
        }
        for (index, char) in chars.enumerated() where matches(punctuation, char) {
            natural.insert(next[index + 1])
        }
        natural.formUnion(projection.offsets.map { next[$0] })
        let hard = Set(input.anchors.filter(\.hardBefore).compactMap { indexAtOffset[$0.range.location] }.map { next[$0] })
        natural.formUnion(hard)
        natural = natural.filter { index in
            guard index > 0, index < chars.count else { return true }
            if insideWord[index] { return hard.contains(index) }
            let before = trim[index] > 0 ? chars[trim[index] - 1] : chars[index - 1]
            let after = chars[index]
            if matches(opening, before) || (matches(punctuation, after) && !matches(opening, after)) { return hard.contains(index) }
            // Typographic connectors are not cue boundaries inside compounds or contractions.
            let connectors: Set<Character> = ["-", "‐", "‑", "'", "’"]
            if index >= 2, connectors.contains(chars[index - 1]), chars[index - 2].isLetter || chars[index - 2].isNumber {
                if after.isLetter || after.isNumber { return hard.contains(index) }
            }
            return true
        }
        for index in 1..<wordEnds.count { wordEnds[index] += wordEnds[index - 1] }
        let cuts = natural.sorted()
        let protected = uniqueProtectedRanges(input.protectedSpans, text: input.text)
        let hints = Set(projection.offsets)
        let anchors = input.anchors.sorted { $0.range.location < $1.range.location }
        let totalStart = input.start ?? anchors.first?.start
        let totalEnd = input.end ?? anchors.last?.end
        var anchorAt = Array<Int?>(repeating: nil, count: chars.count)
        for (index, anchor) in anchors.enumerated() {
            if let lo = indexAtOffset[anchor.range.location], let hi = indexAtOffset[NSMaxRange(anchor.range)], hi > lo {
                for position in lo..<hi { anchorAt[position] = index }
            }
        }
        var followingAnchor = anchorAt
        if chars.count > 1 {
            for index in stride(from: chars.count - 2, through: 0, by: -1) where followingAnchor[index] == nil { followingAnchor[index] = followingAnchor[index + 1] }
        }
        var precedingAnchor = anchorAt
        if chars.count > 1 {
            for index in 1..<chars.count where precedingAnchor[index] == nil { precedingAnchor[index] = precedingAnchor[index - 1] }
        }
        func timing(_ a: Int, _ b: Int) -> Double? {
            if let first = followingAnchor[a], let last = precedingAnchor[b - 1], first <= last {
                return max(0.001, anchors[last].end - anchors[first].start)
            }
            if let start = totalStart, let end = totalEnd, end > start {
                return (end - start) * Double(offsets[b] - offsets[a]) / Double(max(1, source.length))
            }
            return nil
        }
        var pauseAt: [Int: Double] = [:]
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            if left.quality == .aligned, right.quality == .aligned, right.start - left.end >= 0.25,
               let index = indexAtOffset[right.range.location] { pauseAt[next[index]] = right.start - left.end }
        }
        var terminalCount = [0]
        var pauseCost = [0.0]
        for (index, char) in chars.enumerated() {
            terminalCount.append(terminalCount.last! + (sentenceEnds.contains(index + 1) && isTerminal(char) ? 1 : 0))
            let pause = pauseAt[index] ?? 0
            pauseCost.append(pauseCost.last! + (pause >= 0.6 ? min(4, pause * 3) : 0))
        }
        let protectedCost = Dictionary(uniqueKeysWithValues: cuts.map { boundary in
            let utf16 = offsets[boundary]
            return (boundary, 12.0 * Double(protected.filter { $0.location < utf16 && utf16 < NSMaxRange($0) }.count))
        })
        var costs = Array(repeating: Double.infinity, count: cuts.count)
        var previous = Array<Int?>(repeating: nil, count: cuts.count)
        var chosen: [Int: Cue] = [:]
        costs[0] = 0
        for j in 1..<cuts.count {
            try Task.checkCancellation()
            let boundary = cuts[j]
            let b = trim[boundary]
            for i in stride(from: j - 1, through: 0, by: -1) {
                let a = next[cuts[i]]
                guard b > a else { continue }
                if hard.contains(where: { $0 > cuts[i] && $0 < boundary }) { break }
                let range = NSRange(location: offsets[a], length: offsets[b] - offsets[a])
                let text = source.substring(with: range)
                let measured = input.layout.measure(text)
                let overCharacters = input.maximumCharacters.map { b - a > max(1, $0) } ?? false
                let overWords = input.maximumWords.map { wordEnds[b] - wordEnds[a] > max(1, $0) } ?? false
                let overflow = overCharacters || overWords || (fits.map { !$0(text) } ?? !measured.fits)
                // An unbreakable atom is retained and reported, never cut into graphemes.
                if overflow, i != j - 1 {
                    // Custom layout predicates may not be monotonic (e.g. a
                    // caller supplies a complete phrase whitelist).
                    if fits != nil, measured.fits, !overCharacters, !overWords { continue }
                    break
                }
                guard costs[i].isFinite else { continue }
                var score = input.policy.cueCost
                if boundary < chars.count {
                    let terminalEnd = sentenceEnds.contains(b) && isTerminal(chars[b - 1])
                    score += terminalEnd ? -input.policy.terminalReward : (matches(punctuation, chars[b - 1]) ? -input.policy.punctuationReward : input.policy.continuationCost)
                    if hints.contains(boundary) { score -= projection.exact ? input.policy.exactReward : input.policy.projectedReward }
                    score += protectedCost[boundary] ?? 0
                    if let pause = pauseAt[boundary] { score -= min(1.5, pause) }
                }
                if b - a > 1 {
                    score += input.policy.internalTerminalCost * Double(terminalCount[b - 1] - terminalCount[a])
                }
                score += pauseCost[b] - pauseCost[min(b, a + 1)]
                if let duration = timing(a, b) {
                    // A wide dead zone, rather than a fixed preferred cue length.
                    score += 0.15 * pow(max(0, duration - 6), 2) + 0.4 * pow(max(0, duration - 8), 2)
                    if duration < 1, !(sentenceEnds.contains(b) && isTerminal(chars[b - 1])), !hints.contains(boundary) { score += 1 - duration }
                    score += min(1.5, 0.2 * pow(max(0, measured.em / duration - 8) / 8, 2))
                }
                if overflow { score += 100 }
                let cost = costs[i] + score
                if cost < costs[j] {
                    costs[j] = cost
                    previous[j] = i
                    chosen[j] = Cue(range: range, text: text, displayLineBreaks: measured.breaks, layoutOverflow: overflow)
                }
            }
        }
        var cursor = cuts.count - 1
        var cues: [Cue] = []
        while cursor > 0 {
            guard let prior = previous[cursor], let cue = chosen[cursor] else { throw MediaFlowError.invalidLLMOutput("No lossless subtitle path.") }
            cues.append(cue)
            cursor = prior
        }
        cues.reverse()
        guard preservesText(cues.map(\.range), source: input.text) else {
            throw MediaFlowError.invalidLLMOutput("Subtitle ranges do not preserve the finalized text.")
        }
        let overflow = cues.filter(\.layoutOverflow).count
        if overflow > 0 { Log.llm.notice("subtitle elastic layout_overflow=\(overflow) cues=\(cues.count)") }
        let selectedBoundaries = cues.dropLast().compactMap { cue in
            offsets.firstIndex(of: NSMaxRange(cue.range))
        }
        let terminalCuts = selectedBoundaries.filter { sentenceEnds.contains($0) && $0 > 0 && isTerminal(chars[$0 - 1]) }.count
        let suggestedCuts = selectedBoundaries.filter { hints.contains($0) }.count
        let pauseCuts = selectedBoundaries.filter { (pauseAt[$0] ?? 0) >= 0.6 }.count
        let hardCuts = selectedBoundaries.filter { hard.contains($0) }.count
        Log.llm.notice("subtitle elastic decisions cues=\(cues.count) terminal=\(terminalCuts) suggested=\(suggestedCuts) trusted_pause=\(pauseCuts) hard=\(hardCuts) protected_ranges=\(protected.count) layout_overflow=\(overflow)")
        return Result(cues: cues, projection: projection)
    }

    static func preservesText(_ ranges: [NSRange], source text: String) -> Bool {
        let source = text as NSString
        var cursor = 0
        let boundaries = Set(text.indices.map { $0.utf16Offset(in: text) } + [source.length])
        for range in ranges {
            guard range.location >= cursor, NSMaxRange(range) <= source.length, range.length > 0 else { return false }
            let gap = source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            guard gap.allSatisfy(\.isWhitespace), boundaries.contains(range.location), boundaries.contains(NSMaxRange(range)) else { return false }
            cursor = NSMaxRange(range)
        }
        return source.substring(from: cursor).allSatisfy(\.isWhitespace)
    }

    private static func matches(_ regex: NSRegularExpression, _ character: Character) -> Bool {
        let text = String(character)
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }
}
