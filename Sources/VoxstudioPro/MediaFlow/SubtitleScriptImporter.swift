import Foundation
import UniformTypeIdentifiers

/// Lenient SRT/VTT reader for dub scripts. Only spoken text is kept; timings
/// survive solely as pause hints for `DubPunctuationRestorer`.
enum SubtitleScriptImporter {
    struct Cue: Equatable, Sendable {
        var text: String
        var start: Double?
        var end: Double?
        /// A dialogue dash ("- Hi") started the next line, so this turn ends a sentence.
        var endsTurn = false
    }

    enum Failure: LocalizedError, Equatable {
        case unsupportedFormat, tooLarge, unreadable, noSpeech
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Choose an SRT or VTT subtitle file."
            case .tooLarge: "The subtitle file is too large to import."
            case .unreadable: "The subtitle file could not be read. Save it as UTF-8 and try again."
            case .noSpeech: "The subtitle file contains no spoken text."
            }
        }
    }

    static let fileExtensions = ["srt", "vtt"]
    static let maximumBytes = 5_000_000
    static let maximumScriptCharacters = 200_000

    static var contentTypes: [UTType] {
        fileExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func accepts(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(_ url: URL) throws -> [Cue] {
        guard accepts(url) else { throw Failure.unsupportedFormat }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else { throw Failure.tooLarge }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable }
        let cues = parse(try decode(data))
        guard !cues.isEmpty else { throw Failure.noSpeech }
        guard cues.reduce(0, { $0 + $1.text.count }) <= maximumScriptCharacters else { throw Failure.tooLarge }
        return cues
    }

    /// UTF-8/16 first; legacy subtitle encodings (GBK, Big5, Shift-JIS, Latin-1) as fallback.
    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        let legacy: [CFStringEncodings] = [.GB_18030_2000, .big5, .shiftJIS]
        for encoding in legacy {
            let value = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
            if let text = String(data: data, encoding: value), !text.contains("\u{FFFD}") { return text }
        }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw Failure.unreadable
    }

    static func parse(_ contents: String) -> [Cue] {
        let normalized = contents
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = [], current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { blocks.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        var cues: [Cue] = []
        for block in blocks {
            let head = block[0].trimmingCharacters(in: .whitespaces)
            if head.hasPrefix("WEBVTT") || head == "NOTE" || head.hasPrefix("NOTE ")
                || head == "STYLE" || head == "REGION" { continue }
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }) else {
                // A blank line inside a cue splits it; keep that text with the previous cue.
                let text = block.filter { Int($0.trimmingCharacters(in: .whitespaces)) == nil }
                if !cues.isEmpty, !text.isEmpty {
                    appendLines(text, timing: (cues[cues.count - 1].start, cues[cues.count - 1].end), to: &cues, continuing: true)
                }
                continue
            }
            let parts = block[timingIndex].components(separatedBy: "-->")
            let timing = (parts.first.flatMap(timestamp), parts.dropFirst().first.flatMap(timestamp))
            appendLines(Array(block[(timingIndex + 1)...]), timing: timing, to: &cues, continuing: false)
        }
        return removingRollingDuplicates(cues)
    }

    private static func appendLines(
        _ lines: [String], timing: (Double?, Double?), to cues: inout [Cue], continuing: Bool
    ) {
        var turns: [[String]] = []
        for line in lines {
            let raw = line.trimmingCharacters(in: .whitespaces)
            let dialogue = raw.range(of: #"^[-‐–—]\s*"#, options: .regularExpression)
            let text = cleanLine(dialogue.map { String(raw[$0.upperBound...]) } ?? raw)
            guard !text.isEmpty else { continue }
            if dialogue != nil || turns.isEmpty { turns.append([text]) } else { turns[turns.count - 1].append(text) }
        }
        for (offset, turn) in turns.enumerated() {
            let text = TranscriptSegmenter.joinedText(turn)
            if offset == 0, continuing, !cues.isEmpty {
                cues[cues.count - 1].text = TranscriptSegmenter.joinedText([cues[cues.count - 1].text, text])
            } else {
                if offset > 0, !cues.isEmpty { cues[cues.count - 1].endsTurn = true }
                cues.append(Cue(text: text, start: timing.0, end: timing.1))
            }
        }
    }

    /// Removes markup and non-speech annotations a voice model would read aloud.
    static func cleanLine(_ line: String) -> String {
        var text = line
        let removals = [
            #"<[^>]*>"#,                 // HTML, VTT voice/class tags, inline timestamps
            #"\{\\[^}]*\}"#,             // ASS override tags
            #"\[[^\]]*\]"#, #"【[^】]*】"#, // [Music], 【音乐】
            #"♪[^♪]*♪"#, #"[♪♫]"#,
            #"^\([^)]*\)$"#, #"^（[^）]*）$"#, // whole-line (laughs) / （笑）
            #"^[\p{Lu}][\p{Lu}\p{Nd} .'-]{1,30}:\s+"#, // SDH speaker labels: "NARRATOR: "
        ]
        for pattern in removals {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&nbsp;": " ", "&lrm;": "", "&rlm;": ""]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Auto-generated VTT repeats the previous caption line at the start of each cue.
    static func removingRollingDuplicates(_ cues: [Cue]) -> [Cue] {
        var result: [Cue] = []
        for var cue in cues {
            if let previous = result.last {
                let overlap = suffixPrefixOverlap(previous.text, cue.text)
                if overlap > 0 {
                    cue.text = String(cue.text.dropFirst(overlap)).trimmingCharacters(in: .whitespaces)
                    if cue.text.isEmpty {
                        result[result.count - 1].end = cue.end ?? previous.end
                        result[result.count - 1].endsTurn = previous.endsTurn || cue.endsTurn
                        continue
                    }
                }
            }
            result.append(cue)
        }
        return result
    }

    /// Longest previous-suffix == next-prefix that is long enough to be a
    /// repetition artifact (short repeats like "No. No." are real speech).
    private static func suffixPrefixOverlap(_ previous: String, _ next: String) -> Int {
        let a = Array(previous), b = Array(next)
        for length in stride(from: min(a.count, b.count), through: 1, by: -1) {
            guard a[(a.count - length)...].elementsEqual(b[..<length]) else { continue }
            let dense = b[..<length].contains { $0.unicodeScalars.first.map(DubPunctuationRestorer.isDenseScript) ?? false }
            guard length >= (dense ? 3 : 6) else { return 0 }
            let startsAtWord = length == a.count || a[a.count - length - 1].isWhitespace || dense
            let endsAtWord = length == b.count || b[length].isWhitespace || b[length].isPunctuation || dense
            return startsAtWord && endsAtWord ? length : 0
        }
        return 0
    }

    static func timestamp(_ value: String) -> Double? {
        let token = value.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!),
              let minutes = Double(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return total.isFinite && total >= 0 ? total : nil
    }
}
