struct Input: Decodable {
    let id: String
    let language: String
    let text: String
    let budget: String
    let maximum: Int
}
struct Output: Encodable {
    let id: String
    let budget: String
    let lines: [String]
    let nlpCuts: [Int]
    let system: String
    let user: String
    let elapsedMilliseconds: Double
}
let input = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
var output: [Output] = []
for item in input {
    let dense = SubtitleReadabilityPolicy.usesDenseScript(languageCode: item.language, sampleText: item.text)
    let limits = SubtitleReadabilityPolicy.limits(denseScript: dense, overridingMaximum: item.maximum)
    let began = ContinuousClock.now
    let lines = SubtitleReadabilityPolicy.splitTextByLength(item.text, languageCode: item.language, denseScript: dense, limits: limits)
    let elapsed = began.duration(to: .now).components
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.setLanguage(NLLanguage(rawValue: item.language == "zh-Hans" ? "zh-Hans" : item.language))
    tokenizer.string = item.text
    var cuts: Set<Int> = [0, item.text.count]
    tokenizer.enumerateTokens(in: item.text.startIndex..<item.text.endIndex) { range, _ in
        cuts.insert(item.text.distance(from: item.text.startIndex, to: range.lowerBound))
        cuts.insert(item.text.distance(from: item.text.startIndex, to: range.upperBound))
        return true
    }
    output.append(Output(id: item.id, budget: item.budget, lines: lines, nlpCuts: cuts.sorted(),
                         system: SubtitleCascadePrompt.segmentationSystem(languageCode: item.language, limits: limits),
                         user: SubtitleCascadePrompt.segmentationUser(correctedText: item.text, contextBefore: nil, contextAfter: nil, languageCode: item.language, speaker: "A", limits: limits, userInstruction: nil),
                         elapsedMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(output))
