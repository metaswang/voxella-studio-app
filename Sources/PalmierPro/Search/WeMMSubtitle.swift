// Timed subtitle parsing for the WeMM retrieval evaluation.

#if BUNDLED_SPEECH

import Foundation

struct WeMMSubtitleTrack: Sendable {
    struct Cue: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    enum Error: LocalizedError {
        case invalidTimestamp(String)
        case invalidRange(String)
        case noCues

        var errorDescription: String? {
            switch self {
            case .invalidTimestamp(let value):
                "Invalid SRT timestamp: \(value)"
            case .invalidRange(let value):
                "Invalid SRT time range: \(value)"
            case .noCues:
                "SRT contains no usable subtitle cues."
            }
        }
    }

    let cues: [Cue]

    static func load(from url: URL) async throws -> WeMMSubtitleTrack {
        let contents = try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
        return try parse(contents)
    }

    static func parse(_ contents: String) throws -> WeMMSubtitleTrack {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []

        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count == 2 else {
                throw Error.invalidRange(lines[timingIndex])
            }
            let startValue = timingParts[0].trimmingCharacters(in: .whitespaces)
            let endValue = timingParts[1]
                .split(maxSplits: 1, whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            let start = try parseTimestamp(startValue)
            let end = try parseTimestamp(endValue)
            guard start < end else {
                throw Error.invalidRange(lines[timingIndex])
            }

            let text = cleanText(lines[(timingIndex + 1)...].joined(separator: " "))
            guard !text.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: text))
        }

        guard !cues.isEmpty else { throw Error.noCues }
        return WeMMSubtitleTrack(cues: cues.sorted { $0.start < $1.start })
    }

    func text(overlapping range: ClosedRange<Double>) -> String? {
        let text = cues
            .filter { $0.start < range.upperBound && $0.end > range.lowerBound }
            .map(\.text)
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    var fullText: String {
        cues.map(\.text).joined(separator: " ")
    }

    private static func parseTimestamp(_ value: String) throws -> Double {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        let numbers = parts.compactMap { Double($0) }
        guard (parts.count == 2 || parts.count == 3),
            numbers.count == parts.count,
            numbers.allSatisfy({ $0.isFinite && $0 >= 0 })
        else {
            throw Error.invalidTimestamp(value)
        }

        let seconds: Double
        if numbers.count == 2 {
            seconds = numbers[0] * 60 + numbers[1]
        } else {
            seconds = numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
        }
        guard seconds.isFinite else { throw Error.invalidTimestamp(value) }
        return seconds
    }

    private static func cleanText(_ value: String) -> String {
        let withoutHTML = value.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression)
        let withoutASS = withoutHTML.replacingOccurrences(
            of: "\\{[^}]+\\}",
            with: "",
            options: .regularExpression)
        return withoutASS.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

#endif
