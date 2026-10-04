import Foundation
import NaturalLanguage

/// CPU-only TTS planning. All output is sliced from one immutable source string.
enum DubChunkPlanner {
    static let version = "rules-v1"

    struct Budget: Sendable {
        // Initial operating budget, not a claim about the model's optimal length.
        var maximumTextTokens = 64
        var maximumUTF8Bytes = 4_096
        var maximumCharacters: Int? = nil
        var preferredSeconds: Double = 14
        var maximumEstimatedSeconds: Double = 28
        var maximumLookbackUnits = 64
    }

    enum Failure: LocalizedError {
        case invalidBudget, unbreakableText, noLosslessPath
        var errorDescription: String? {
            switch self {
            case .invalidBudget: "The dub text budget is invalid."
            case .unbreakableText: "A word or text identifier exceeds the voice model's input budget."
            case .noLosslessPath: "The dub text could not be divided without losing source content."
            }
        }
    }

    struct Unit: Sendable {
        var id: String
        var range: NSRange
        var text: String
        var paragraphBefore: Bool
        var forcedBefore: Bool
    }

    struct Chunk: Sendable {
        /// Includes inter-unit whitespace, so ranges partition the entire source.
        var range: NSRange
        var text: String
        var endUnitID: String
        var textTokens: Int
        var estimatedSeconds: Double
        var forcedBoundary: Bool
        var reasons: [String]
    }

    struct Plan: Sendable {
        var source: String
        var language: String
        var units: [Unit]
        var chunks: [Chunk]
    }

    private struct Protection {
        var start: Int
        var end: Int
        var lexical: Bool
        var suppressSentenceEnd = false
    }

    private struct Profile {
        var code: String
        var charactersPerSecond: Double
        var transitions: [String]
        var sceneStarts: [String]
        var sceneActions: [String]
        var continuations: [String]
        var closures: [String]
        var stopWords: Set<String>

        static func forText(_ text: String, language: String) -> Profile {
            let supplied = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            let detected: String? = if supplied == nil || supplied == "auto" {
                NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
            } else { supplied }
            let code = detected?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "und"
            var profile = Profile(code: code, charactersPerSecond: 13,
                transitions: [], sceneStarts: [], sceneActions: [], continuations: [], closures: [], stopWords: [])
            switch code {
            case "en":
                profile.charactersPerSecond = 14.5
                profile.transitions = ["later", "afterwards", "meanwhile", "the next", "eventually"]
                profile.sceneStarts = ["as ", "when ", "after "]
                profile.sceneActions = ["walked home", "went home", "returned home", "returned to", "arrived at", "left the", "walked away"]
                profile.continuations = ["she ", "he ", "they ", "it ", "this ", "that ", "because ", "therefore ", "instead "]
                profile.closures = ["thanked", "replied", "answered", "said goodbye"]
                profile.stopWords = Set("a an the and or but of to in on at for with as is was were had have it she he they this that".split(separator: " ").map(String.init))
            case "zh", "yue":
                profile.charactersPerSecond = 6.3
                profile.transitions = ["后来", "随后", "之后", "过了一", "第二天", "与此同时", "分钟后", "小时后"]
                profile.sceneStarts = ["当", "于是", "随后"]
                profile.sceneActions = ["回家", "回到", "离开", "来到"]
                profile.continuations = ["她", "他", "它", "这", "那", "因为", "所以", "因此", "不过"]
                profile.closures = ["道谢", "感谢", "回答", "告别"]
                profile.stopWords = ["的", "了", "是", "在", "和", "她", "他", "这", "那"]
            case "ja":
                profile.charactersPerSecond = 7.1
                profile.transitions = ["その後", "しばらくして", "翌日", "一方", "分後", "時間後"]
                profile.sceneStarts = ["帰", "その後"]
                profile.sceneActions = ["帰宅", "家に帰", "戻", "立ち去"]
                profile.continuations = ["彼女", "彼は", "それ", "この", "だから", "しかし"]
                profile.closures = ["答え", "感謝", "礼を", "別れ"]
                profile.stopWords = ["の", "は", "が", "に", "を", "と", "で", "です", "た"]
            case "ko":
                profile.charactersPerSecond = 6.5
                profile.transitions = ["그 후", "잠시 후", "다음 날", "한편", "분 후", "시간 후"]
                profile.sceneStarts = ["집으로", "그 후", "돌아"]
                profile.sceneActions = ["집", "돌아", "떠나"]
                profile.continuations = ["그녀", "그는", "이것", "그래서", "왜냐하면"]
                profile.closures = ["감사", "대답", "작별"]
            case "de":
                profile.transitions = ["später", "danach", "inzwischen", "am nächsten"]
                profile.sceneStarts = ["als ", "während ", "nachdem "]
                profile.sceneActions = ["nach hause", "zurückkehr", "verließ", "ankam"]
                profile.continuations = ["sie ", "er ", "es ", "dies", "weil ", "deshalb "]
                profile.closures = ["dankte", "antwortete", "verabschiedete"]
            case "fr":
                profile.charactersPerSecond = 13.4
                profile.transitions = ["plus tard", "ensuite", "le lendemain", "pendant ce temps"]
                profile.sceneStarts = ["en ", "alors que ", "quand ", "après "]
                profile.sceneActions = ["rentr", "retourn", "quitta", "arriva"]
                profile.continuations = ["elle ", "il ", "ils ", "cela", "parce que ", "donc "]
                profile.closures = ["remercia", "répondit", "au revoir"]
            case "es":
                profile.charactersPerSecond = 14.4
                profile.transitions = ["más tarde", "después", "al día siguiente", "mientras tanto"]
                profile.sceneStarts = ["mientras ", "cuando ", "al "]
                profile.sceneActions = ["casa", "regres", "salió", "lleg"]
                profile.continuations = ["ella ", "él ", "esto", "porque ", "por eso "]
                profile.closures = ["agradeció", "respondió", "despidió"]
            case "pt":
                profile.charactersPerSecond = 13.5
                profile.transitions = ["mais tarde", "depois", "no dia seguinte", "enquanto isso"]
                profile.sceneStarts = ["enquanto ", "quando ", "ao "]
                profile.sceneActions = ["casa", "volt", "regress", "saiu", "cheg"]
                profile.continuations = ["ela ", "ele ", "isso", "porque ", "por isso "]
                profile.closures = ["agradeceu", "respondeu", "despediu"]
            case "it":
                profile.charactersPerSecond = 14
                profile.transitions = ["più tardi", "dopo", "il giorno dopo", "nel frattempo"]
                profile.sceneStarts = ["mentre ", "quando ", "dopo "]
                profile.sceneActions = ["casa", "torn", "ritorn", "lasci", "arriv"]
                profile.continuations = ["lei ", "lui ", "questo", "perché ", "quindi "]
                profile.closures = ["ringraziò", "rispose", "salutò"]
            case "ru":
                profile.charactersPerSecond = 12.5
                profile.transitions = ["позже", "затем", "на следующий день", "тем временем"]
                profile.sceneStarts = ["когда ", "пока ", "после "]
                profile.sceneActions = ["домой", "вернул", "ушёл", "ушла", "пришёл", "пришла"]
                profile.continuations = ["она ", "он ", "это", "потому что ", "поэтому "]
                profile.closures = ["поблагодар", "ответил", "попрощал"]
            default: break // Unknown languages retain structural and resource rules.
            }
            func fold(_ values: [String]) -> [String] {
                values.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: code)) }
            }
            profile.transitions = fold(profile.transitions)
            profile.sceneStarts = fold(profile.sceneStarts)
            profile.sceneActions = fold(profile.sceneActions)
            profile.continuations = fold(profile.continuations)
            profile.closures = fold(profile.closures)
            return profile
        }
    }

    /// No model is loaded here. Production injects the installed Qwen tokenizer.
    static func plan(_ text: String, language: String, budget: Budget = Budget(),
                     tokenCount: (String) -> Int) throws -> Plan {
        try Task.checkCancellation()
        guard budget.maximumTextTokens > 0, budget.maximumUTF8Bytes > 0,
              budget.maximumCharacters.map({ $0 > 0 }) ?? true,
              budget.preferredSeconds.isFinite, budget.preferredSeconds > 0,
              budget.maximumEstimatedSeconds.isFinite,
              budget.maximumEstimatedSeconds >= budget.preferredSeconds,
              budget.maximumLookbackUnits > 0 else { throw Failure.invalidBudget }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Plan(source: text, language: language, units: [], chunks: [])
        }
        let profile = Profile.forText(text, language: language)
        let source = text as NSString
        let chars = Array(text)
        var offsets = [0], byteOffsets = [0], spokenOffsets = [0]
        for c in chars {
            offsets.append(offsets.last! + String(c).utf16.count)
            byteOffsets.append(byteOffsets.last! + String(c).utf8.count)
            spokenOffsets.append(spokenOffsets.last! + (c.isWhitespace ? 0 : 1))
        }
        // Constant-time trimming and resource checks even for an oversized paragraph.
        var nextContent = Array(repeating: chars.count, count: chars.count + 1)
        var contentEnd = Array(repeating: 0, count: chars.count + 1)
        for i in chars.indices { contentEnd[i + 1] = chars[i].isWhitespace ? contentEnd[i] : i + 1 }
        for i in chars.indices.reversed() { nextContent[i] = chars[i].isWhitespace ? nextContent[i + 1] : i }
        let positions = Dictionary(uniqueKeysWithValues: offsets.enumerated().map { ($0.element, $0.offset) })
        let protected = protections(text, chars: chars, positions: positions)
        let lexicalRanges = wordRanges(text, language: profile.code).compactMap { range -> Range<Int>? in
            guard let a = positions[range.location], let b = positions[NSMaxRange(range)] else { return nil }
            return a..<b
        }
        var lexicalDelta = Array(repeating: 0, count: chars.count + 1)
        var quotationDelta = lexicalDelta
        for range in lexicalRanges where range.count > 1 {
            lexicalDelta[range.lowerBound + 1] += 1; lexicalDelta[range.upperBound] -= 1
        }
        for span in protected where span.end > span.start + 1 {
            if span.lexical { lexicalDelta[span.start + 1] += 1; lexicalDelta[span.end] -= 1 }
            else { quotationDelta[span.start + 1] += 1; quotationDelta[span.end] -= 1 }
        }
        for i in 1..<lexicalDelta.count {
            lexicalDelta[i] += lexicalDelta[i - 1]; quotationDelta[i] += quotationDelta[i - 1]
        }
        func safe(_ p: Int, allowQuotation: Bool = false) -> Bool {
            lexicalDelta[p] == 0 && (allowQuotation || quotationDelta[p] == 0)
        }
        func afterClosersAndSpace(_ p: Int) -> Int {
            var end = p
            while end > 0, chars[end - 1].isWhitespace { end -= 1 }
            while end < chars.count, "\"'”’“»›」』》）)]}］｝".contains(chars[end]) { end += 1 }
            while end < chars.count, chars[end].isWhitespace { end += 1 }
            return end
        }
        var rawSentenceCuts: Set<Int> = [chars.count]
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if profile.code != "und" { tokenizer.setLanguage(NLLanguage(rawValue: profile.code)) }
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let p = positions[range.upperBound.utf16Offset(in: text)] {
                rawSentenceCuts.insert(afterClosersAndSpace(p))
            }
            return true
        }
        // Supplement the native segmenter for scripts with explicit sentence terminators.
        for i in chars.indices {
            if "。！？؟!?".contains(chars[i]) || (i > 0 && chars[i - 1] == "\n" && chars[i] == "\n") {
                rawSentenceCuts.insert(afterClosersAndSpace(i + 1))
            }
        }
        // Native sentence segmentation can treat titles such as "Mr." as a sentence.
        for span in protected where span.suppressSentenceEnd {
            let end = afterClosersAndSpace(span.end)
            if end < chars.count { rawSentenceCuts.remove(end) }
        }
        try Task.checkCancellation()
        var cuts = Set(rawSentenceCuts.filter { $0 > nextContent[0] && safe($0) })
        cuts.insert(chars.count)
        var forcedCuts: Set<Int> = []
        var measured: [NSRange: (tokens: Int, seconds: Double)] = [:]
        func measure(_ a: Int, _ b: Int) -> (tokens: Int, seconds: Double, text: String) {
            let range = NSRange(location: offsets[a], length: offsets[b] - offsets[a])
            let value = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let result = measured[range] ?? (tokenCount(value), estimatedSeconds(value, profile: profile))
            measured[range] = result
            return (result.tokens, result.seconds, value)
        }
        func withinStructuralBudget(_ a: Int, _ b: Int) -> Bool {
            let start = min(b, nextContent[a]), end = max(start, contentEnd[b])
            return byteOffsets[end] - byteOffsets[start] <= budget.maximumUTF8Bytes
                && (budget.maximumCharacters.map { end - start <= $0 } ?? true)
                && Double(spokenOffsets[end] - spokenOffsets[start]) / profile.charactersPerSecond <= budget.maximumEstimatedSeconds
        }
        func fits(_ a: Int, _ b: Int) -> Bool {
            withinStructuralBudget(a, b) && measure(a, b).tokens <= budget.maximumTextTokens
        }
        var fallbackRanks: [Int: Int] = [:]
        func addFallback(_ p: Int, rank: Int) {
            let end = afterClosersAndSpace(p)
            guard end > 0, safe(end, allowQuotation: true) else { return }
            fallbackRanks[end] = min(fallbackRanks[end] ?? rank, rank)
        }
        for cut in rawSentenceCuts { addFallback(cut, rank: 0) }
        for i in chars.indices {
            if ";:；：".contains(chars[i]) { addFallback(i + 1, rank: 1) }
            else if ",，、،".contains(chars[i]) { addFallback(i + 1, rank: 2) }
        }
        for range in lexicalRanges { addFallback(range.upperBound, rank: 3) }
        let fallback = fallbackRanks.sorted { $0.key < $1.key }
        var fallbackCursor = 0
        // Expand only oversized atoms. Quotes may continue; words/identifiers never split.
        var previous = 0
        for end in cuts.sorted() {
            var start = previous
            while !fits(start, end) {
                try Task.checkCancellation()
                while fallbackCursor < fallback.count, fallback[fallbackCursor].key <= start { fallbackCursor += 1 }
                var candidates: [(Int, Int)] = []
                for candidate in fallback[fallbackCursor...] {
                    let p = candidate.key
                    if p >= end || !withinStructuralBudget(start, p) { break }
                    if fits(start, p) { candidates.append((p, candidate.value)) }
                }
                // Prefer a sentence/clause; within that level take the longest fitting prefix.
                guard let best = candidates.min(by: { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 < $1.1 }) else {
                    throw Failure.unbreakableText
                }
                cuts.insert(best.0); forcedCuts.insert(best.0); start = best.0
            }
            previous = end
        }
        let nodes = [0] + cuts.sorted()
        var units: [Unit] = []
        for i in 1..<nodes.count {
            let range = NSRange(location: offsets[nodes[i - 1]], length: offsets[nodes[i]] - offsets[nodes[i - 1]])
            let raw = source.substring(with: range)
            units.append(Unit(id: String(format: "U%03d", i), range: range,
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                paragraphBefore: i > 1 && String(source.substring(with: units[i - 2].range)
                    .reversed().prefix(while: { $0.isWhitespace })).contains("\n\n"),
                forcedBefore: forcedCuts.contains(nodes[i - 1])))
        }
        let signals = boundarySignals(units, profile: profile)
        var transitionPrefix = [Double.zero]
        for signal in signals { transitionPrefix.append(transitionPrefix.last! + signal.transition) }
        var costs = Array(repeating: Double.infinity, count: nodes.count)
        var predecessors = Array<Int?>(repeating: nil, count: nodes.count)
        costs[0] = 0
        for j in 1..<nodes.count {
            try Task.checkCancellation()
            for i in stride(from: j - 1, through: max(0, j - budget.maximumLookbackUnits), by: -1) {
                guard costs[i].isFinite, fits(nodes[i], nodes[j]) else { continue }
                let m = measure(nodes[i], nodes[j])
                let final = j == nodes.count - 1
                let lengthCost = (!final || m.seconds >= 6) ? 0.018 * pow(m.seconds - budget.preferredSeconds, 2) : 0
                let tinyCost = final ? 0 : 0.12 * pow(max(0, 6 - m.seconds), 2)
                let internalTransitions = transitionPrefix[j - 1] - transitionPrefix[i]
                let edge = final ? 0 : signals[j - 1].cost
                let cost = costs[i] + 2 + lengthCost + tinyCost + 2 * internalTransitions + edge
                if cost < costs[j] - 1e-9 {
                    costs[j] = cost; predecessors[j] = i
                }
            }
        }
        var chunks: [Chunk] = []
        var cursor = nodes.count - 1
        while cursor > 0 {
            guard let start = predecessors[cursor] else { throw Failure.noLosslessPath }
            let m = measure(nodes[start], nodes[cursor])
            chunks.append(Chunk(range: NSRange(location: offsets[nodes[start]], length: offsets[nodes[cursor]] - offsets[nodes[start]]),
                text: m.text, endUnitID: units[cursor - 1].id, textTokens: m.tokens,
                estimatedSeconds: m.seconds, forcedBoundary: forcedCuts.contains(nodes[cursor]),
                reasons: cursor == units.count ? ["end"] : signals[cursor - 1].reasons))
            cursor = start
        }
        chunks.reverse()
        guard chunks.map({ source.substring(with: $0.range) }).joined().utf8.elementsEqual(text.utf8) else {
            throw Failure.noLosslessPath
        }
        return Plan(source: text, language: profile.code, units: units, chunks: chunks)
    }

    /// Only for synchronous previews/tests without an installed tokenizer.
    /// Live generation never uses this estimate as its token budget.
    static func estimatedTokenCount(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 5)))
    }

    private static func wordRanges(_ text: String, language: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if language != "und" { tokenizer.setLanguage(NLLanguage(rawValue: language)) }
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(NSRange(range, in: text)); return true
        }
        return ranges
    }

    private static func estimatedSeconds(_ text: String, profile: Profile) -> Double {
        Double(text.filter { !$0.isWhitespace }.count) / profile.charactersPerSecond
    }

    private struct Signal { var cost: Double; var transition: Double; var reasons: [String] }

    private static func boundarySignals(_ units: [Unit], profile: Profile) -> [Signal] {
        let folded = units.map { $0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: profile.code)) }
        let words: [Set<String>] = folded.map { value in
            Set(wordRanges(value, language: profile.code).map { (value as NSString).substring(with: $0) }
                .filter { $0.count > 1 && $0.contains(where: \.isLetter) && !profile.stopWords.contains($0) })
        }
        var dependency: [Int: Double] = [:]
        // A quoted question, nearby response, and closing attribution form a dialogue episode.
        for q in units.indices where units[q].text.contains(where: { "?？؟".contains($0) })
            && units[q].text.contains(where: { "\"“«「『„".contains($0) }) {
            if let answer = ((q + 1)..<min(units.count, q + 4)).first(where: {
                units[$0].text.first.map { "\"“«「『„".contains($0) } ?? false
            }) {
                for boundary in q..<answer { dependency[boundary] = max(dependency[boundary] ?? 0, 5) }
                if answer + 1 < units.count, profile.closures.contains(where: { folded[answer + 1].contains($0) }) {
                    dependency[answer] = max(dependency[answer] ?? 0, 3)
                }
            }
        }
        return units.indices.map { i in
            guard i + 1 < units.count else { return Signal(cost: 0, transition: 0, reasons: ["end"]) }
            let next = folded[i + 1]
            var cost = terminal(units[i].text) ? -0.6 : 4.0
            var reasons = [terminal(units[i].text) ? "sentence" : "continuation"]
            var transition = units[i + 1].paragraphBefore ? 5.0 : 0
            if transition > 0 { reasons.append("paragraph") }
            let prefix = String(next.prefix(72))
            let temporal = profile.transitions.contains { marker in
                if marker.contains(" ") || marker.first?.isASCII != true { return prefix.contains(marker) }
                return prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(6).contains(Substring(marker))
            }
            let scene = profile.sceneStarts.contains(where: { next.hasPrefix($0) })
                && profile.sceneActions.contains(where: { prefix.contains($0) })
            if temporal || scene { transition = max(transition, 6); reasons.append(temporal ? "time-transition" : "scene-transition") }
            if transition == 0, profile.continuations.contains(where: { next.hasPrefix($0) }) {
                cost += 1; reasons.append("reference-continuity")
            }
            if let penalty = dependency[i] { cost += penalty; reasons.append("dialogue") }
            if !words[i].isEmpty, !words[i + 1].isEmpty {
                let overlap = Double(words[i].intersection(words[i + 1]).count) / Double(words[i].union(words[i + 1]).count)
                cost += 0.5 * overlap
                if overlap > 0 { reasons.append("lexical-continuity") }
            }
            if units[i + 1].forcedBefore { cost += 12; reasons.append("budget-fallback") }
            return Signal(cost: cost - transition, transition: transition, reasons: reasons)
        }
    }

    private static func terminal(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’“»›」』》）)]}］｝ "))
        return value.last.map { ".!?。！？؟…".contains($0) } ?? false
    }

    private static func protections(_ text: String, chars: [Character], positions: [Int: Int]) -> [Protection] {
        var result: [Protection] = []
        var stack: [(start: Int, close: Character)] = []
        let pairs: [Character: Character] = ["“": "”", "‘": "’", "„": "“", "«": "»", "‹": "›", "「": "」", "『": "』", "《": "》", "(": ")", "（": "）", "[": "]", "{": "}", "［": "］", "｛": "｝"]
        for i in chars.indices {
            let c = chars[i]
            let apostrophe = "'’".contains(c) && i > 0 && chars[i - 1].isLetter
                && ((i + 1 < chars.count && chars[i + 1].isLetter) || stack.last?.close != c)
            if apostrophe || (i > 0 && chars[i - 1] == "\\") { continue }
            if let top = stack.last, c == top.close {
                result.append(Protection(start: top.start, end: i + 1, lexical: false)); stack.removeLast()
            } else if let close = pairs[c] { stack.append((i, close)) }
            else if c == "\"" || c == "'" { stack.append((i, c)) }
        }
        for top in stack { result.append(Protection(start: top.start, end: chars.count, lexical: false)) }
        let patterns = [
            #"(?i)(?:https?://|www\.)[^\s<>]+|[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}"#,
            #"(?<![\p{L}\p{N}])\p{N}+(?:[.,:/-]\p{N}+)+"#,
            #"(?i)\b(?:\p{L}\.){2,}|\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|Mme|Mlle|Herr|Frau|Sig|Sra|Srta|St)\."#
        ]
        for (patternIndex, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
                guard let a = positions[match.range.location], var b = positions[NSMaxRange(match.range)] else { continue }
                if pattern == patterns[0] {
                    while b > a, ".!?。！？\"'”’»」』)]}".contains(chars[b - 1]) { b -= 1 }
                }
                result.append(Protection(start: a, end: b, lexical: true, suppressSentenceEnd: patternIndex == 2))
            }
        }
        return result
    }
}
