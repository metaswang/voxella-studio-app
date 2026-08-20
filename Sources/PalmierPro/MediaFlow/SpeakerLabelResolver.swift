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
}
