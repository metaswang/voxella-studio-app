import Foundation

/// Reading groups retain their original cues for exact playback and editing.
struct SessionTranscriptParagraph: Identifiable {
    var cues: [SubtitleCue]
    var id: Int { cues[0].id }
    var end: Double { cues.map(\.end).max() ?? 0 }

    static func group(_ cues: [SubtitleCue], aggregate: Bool = true) -> [Self] {
        var result: [Self] = []
        for cue in cues {
            let speaker = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if aggregate, !speaker.isEmpty, let last = result.last,
               last.cues[0].speaker?.trimmingCharacters(in: .whitespacesAndNewlines) == speaker {
                result[result.count - 1].cues.append(cue)
            } else {
                result.append(Self(cues: [cue]))
            }
        }
        return result
    }

    static func separator(_ left: String, _ right: String) -> String {
        // Reuse the established display normalization for CJK and punctuation.
        let joined = TranscriptSegmenter.joinedText([left, right])
        return joined.contains(left + right) ? "" : " "
    }
}

/// Flat identities keep LazyVStack from reusing nested cue and paragraph rows after a split.
enum SessionTranscriptDisplayRow: Identifiable {
    case paragraph(SessionTranscriptParagraph)
    case cue(SubtitleCue)
    case divider(Int)
    case done(Int)

    var id: String {
        switch self {
        case .paragraph(let paragraph): return "paragraph-\(paragraph.id)"
        case .cue(let cue): return "cue-\(cue.id)"
        case .divider(let id): return "divider-\(id)"
        case .done(let id): return "done-\(id)"
        }
    }

    static func rows(_ cues: [SubtitleCue], aggregate: Bool, expandedID: Int?, allowsEditing: Bool) -> [Self] {
        let paragraphs = SessionTranscriptParagraph.group(cues, aggregate: aggregate)
        return paragraphs.enumerated().flatMap { index, paragraph -> [Self] in
            let boundary: [Self] = allowsEditing && index < paragraphs.count - 1 ? [.divider(paragraph.cues.last!.id)] : []
            if aggregate && expandedID != paragraph.id { return [.paragraph(paragraph)] + boundary }
            var rows: [Self] = []
            for (index, cue) in paragraph.cues.enumerated() {
                rows.append(.cue(cue))
                if allowsEditing && index < paragraph.cues.count - 1 { rows.append(.divider(cue.id)) }
            }
            if aggregate && allowsEditing { rows.append(.done(paragraph.id)) }
            return rows + boundary
        }
    }

    static func scrollID(cueID: Int, in cues: [SubtitleCue], aggregate: Bool, expandedID: Int?) -> String {
        guard aggregate, let paragraph = SessionTranscriptParagraph.group(cues).first(where: {
            $0.cues.contains(where: { $0.id == cueID })
        }), paragraph.id != expandedID else { return "cue-\(cueID)" }
        return "paragraph-\(paragraph.id)"
    }
}
