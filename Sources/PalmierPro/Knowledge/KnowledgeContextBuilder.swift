import Foundation

struct KnowledgeSessionContextMetadata: Sendable {
    var title: String
    var summary: String?
    var duration: Double = 0
    var sessionType: WorkbenchSessionType = .upload
    var sourceOrigin: KnowledgeSourceOrigin = .local
    var sourceCreatedAt: Double? = nil
    var sourceModifiedAt: Double? = nil
}

enum KnowledgeContextBuilder {
    static let metadataPerSessionLimit = 360
    static let metadataTotalLimit = 1_500
    static let shortAnchorLimit = 350
    static let mergedAnchorLimit = 850

    static func build(
        anchors: [SessionSearchHit],
        metadata: [UUID: KnowledgeSessionContextMetadata],
        neighbors: [Int: [SessionSearchHit]],
        maxChars: Int
    ) -> String {
        let budget = max(1, maxChars)
        var used = 0
        var metadataUsed = 0
        var seenSessions = Set<UUID>()
        let anchorIDs = Set(anchors.map(\.unitID))
        var renderedAnchors = Set<Int>()
        var consumedNeighbors = Set<Int>()
        var blocks: [String] = []

        for (index, anchor) in anchors.enumerated() where renderedAnchors.insert(anchor.unitID).inserted {
            var prefix = ""
            if seenSessions.insert(anchor.sessionID).inserted,
               let source = metadata[anchor.sessionID]
            {
                let title = clipped(source.title, limit: metadataPerSessionLimit)
                let summary = clipped(source.summary ?? "", limit: metadataPerSessionLimit)
                var details = ["Session title: \(title)"]
                if source.duration > 0 {
                    details.append("Session duration: \(formatDuration(source.duration))")
                }
                details.append("Session type: \(source.sessionType.rawValue)")
                details.append("Session origin: \(source.sourceOrigin.rawValue)")
                if let date = formatDate(source.sourceCreatedAt) {
                    details.append("Session date: \(date)")
                }
                if let date = formatDate(source.sourceModifiedAt) {
                    details.append("Session modified: \(date)")
                }
                let raw = (details + [summary.isEmpty ? nil : "Session summary: \(summary)"])
                    .compactMap { $0 }
                    .joined(separator: "\n")
                let remaining = max(0, metadataTotalLimit - metadataUsed)
                prefix = clipped(raw, limit: remaining)
                metadataUsed += prefix.count
            }

            let merged = merge(
                anchor: anchor,
                neighbors: neighbors[anchor.unitID] ?? [],
                anchorIDs: anchorIDs,
                consumedNeighbors: &consumedNeighbors
            )
            let start = anchor.start.map(KnowledgeSourceRef.formatTimestamp) ?? "—"
            let end = anchor.end.map(KnowledgeSourceRef.formatTimestamp) ?? "—"
            let speakers = anchor.speakerLabels.isEmpty ? "—" : anchor.speakerLabels.joined(separator: ", ")
            let body = """
            [\(index + 1)] session=\(anchor.sessionID.uuidString)
            time=\(start)–\(end) speakers=\(speakers)
            \(merged)
            """
            let block = [prefix.isEmpty ? nil : prefix, body].compactMap { $0 }.joined(separator: "\n")
            guard !block.isEmpty else { continue }
            if used + block.count > budget, !blocks.isEmpty { break }
            blocks.append(block)
            used += block.count
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func merge(
        anchor: SessionSearchHit,
        neighbors: [SessionSearchHit],
        anchorIDs: Set<Int>,
        consumedNeighbors: inout Set<Int>
    ) -> String {
        let anchorText = clipped(anchor.text.trimmingCharacters(in: .whitespacesAndNewlines), limit: mergedAnchorLimit)
        guard anchorText.count < shortAnchorLimit else { return anchorText }
        let ordered = neighbors.sorted {
            let lhsStart = $0.start ?? -Double.infinity
            let rhsStart = $1.start ?? -Double.infinity
            return lhsStart == rhsStart ? $0.unitID < $1.unitID : lhsStart < rhsStart
        }
        var fragments: [(Double, String)] = [(anchor.start ?? 0, anchorText)]
        var used = anchorText.count
        for neighbor in ordered
            where !anchorIDs.contains(neighbor.unitID) && consumedNeighbors.insert(neighbor.unitID).inserted
        {
            let text = neighbor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let remaining = mergedAnchorLimit - used
            guard remaining > 1 else { break }
            let addition = clipped(text, limit: remaining - 1)
            guard !addition.isEmpty else { continue }
            fragments.append((neighbor.start ?? 0, addition))
            used += addition.count + 1
        }
        return fragments.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        guard limit > 0, !value.isEmpty else { return "" }
        guard value.count > limit else { return value }
        guard limit > 1 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private static func formatDate(_ timestamp: Double?) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
    }
}
