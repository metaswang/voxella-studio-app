import Foundation
import NaturalLanguage

enum KnowledgeLexicalTerms {
    static func terms(_ text: String) -> [String] {
        let value = text.precomposedStringWithCanonicalMapping.lowercased()
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = value
        var terms: [String] = []
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
            terms.append(String(value[range])); return true
        }
        var previous: Character?
        for character in value {
            let isCJK = character.unicodeScalars.contains { scalar in
                (0x3400...0x9fff).contains(scalar.value) || (0x3040...0x30ff).contains(scalar.value) || (0xac00...0xd7af).contains(scalar.value)
            }
            if isCJK {
                if let previous { terms.append(String(previous) + String(character)) }
                previous = character
            } else { previous = nil }
        }
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func indexText(_ text: String) -> String { text + "\n" + terms(text).joined(separator: " ") }
    static func query(_ text: String) -> String {
        terms(text).prefix(64).map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " OR ")
    }
}
