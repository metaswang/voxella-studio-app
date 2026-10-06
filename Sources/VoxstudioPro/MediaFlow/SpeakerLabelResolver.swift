import Foundation

enum SpeakerLabelResolver {
    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func dominant(in values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, value) in values.enumerated() {
            guard let speaker = normalized(value) else { continue }
            counts[speaker, default: 0] += 1
            if firstSeen[speaker] == nil { firstSeen[speaker] = index }
        }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value
                ? (firstSeen[lhs.key] ?? .max) > (firstSeen[rhs.key] ?? .max)
                : lhs.value < rhs.value
        }?.key
    }

    /// Renumbers speaker labels by first appearance in time, so slot gaps such as
    /// "Speaker 1" / "Speaker 3" become a contiguous "Speaker 1" / "Speaker 2".
    static func canonicalizedByFirstAppearance(_ words: [TranscriptionWord]) -> [TranscriptionWord] {
        var order: [String] = []
        var seen = Set<String>()
        let timed = words.enumerated().sorted { lhs, rhs in
            let left = lhs.element.start ?? .infinity
            let right = rhs.element.start ?? .infinity
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        for item in timed {
            guard let speaker = normalized(item.element.speaker), seen.insert(speaker).inserted else { continue }
            order.append(speaker)
        }
        guard order.enumerated().contains(where: { $0.element != "Speaker \($0.offset + 1)" }) else {
            return words
        }
        let mapping = Dictionary(uniqueKeysWithValues: order.enumerated().map { offset, speaker in
            (speaker, "Speaker \(offset + 1)")
        })
        return words.map { word in
            guard let speaker = normalized(word.speaker), let canonical = mapping[speaker], canonical != word.speaker else {
                return word
            }
            return TranscriptionWord(
                text: word.text,
                start: word.start,
                end: word.end,
                speaker: canonical,
                speakerConfidence: word.speakerConfidence,
                speakerBoundary: word.speakerBoundary,
                timingQuality: word.timingQuality
            )
        }
    }
}
