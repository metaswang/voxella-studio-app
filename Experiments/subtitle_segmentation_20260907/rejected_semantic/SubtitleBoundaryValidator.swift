import Foundation

enum SubtitleBoundaryValidator {
    static func sourceSlices(sourceText: String, proposedLines: [String]) -> [String]? {
        guard !proposedLines.isEmpty else { return nil }
        var cursor = sourceText.startIndex
        var slices: [String] = []
        for rawLine in proposedLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            while cursor < sourceText.endIndex, sourceText[cursor].isWhitespace {
                cursor = sourceText.index(after: cursor)
            }
            guard let end = sourceText.index(cursor, offsetBy: line.count, limitedBy: sourceText.endIndex),
                  sourceText[cursor..<end].utf8.elementsEqual(line.utf8) else { return nil }
            slices.append(String(sourceText[cursor..<end]))
            cursor = end
        }
        while cursor < sourceText.endIndex, sourceText[cursor].isWhitespace {
            cursor = sourceText.index(after: cursor)
        }
        return cursor == sourceText.endIndex ? slices : nil
    }

    struct Repair: Decodable {
        let id: Int
        let lines: [String]
    }

    static func applyingRepairs(_ repairs: [Repair], to lines: [String], indices: [Int]) -> [String]? {
        let allowed = Set(indices)
        guard repairs.count == indices.count, allowed.count == indices.count,
              indices.allSatisfy({ lines.indices.contains($0) }) else { return nil }
        var replacements: [Int: [String]] = [:]
        for repair in repairs {
            guard lines.indices.contains(repair.id), allowed.contains(repair.id), replacements[repair.id] == nil,
                  let slices = sourceSlices(sourceText: lines[repair.id], proposedLines: repair.lines)
            else { return nil }
            replacements[repair.id] = slices
        }
        return lines.enumerated().flatMap { replacements[$0.offset] ?? [$0.element] }
    }

}
