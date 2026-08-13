import Foundation

struct TranscriptionAlignmentDiagnostics: Codable, Equatable, Sendable {
    var trimmedHallucinatedSpanCount: Int
    var rejectedAlignmentChunkCount: Int
    var retriedAlignmentChunkCount: Int
    var estimatedUnitCount: Int
    var longestRejectedUnitDuration: Double?
    var removedDuplicatePrefixes: Int
    var removedDuplicateSuffixes: Int
    var removedContainedSpans: Int
    var atomicSegmentFallbackCount: Int
    var reconciledBoundaryCount: Int
    var unresolvedBoundaryCount: Int
    var retriedUncoveredRangeCount: Int
    var retriedUncoveredSpeechSeconds: Double
    var retriedUncoveredAcceptedCount: Int
    var retriedUncoveredKeptFirstPassCount: Int
    var rawLexicalUnitCount: Int
    var qualityLexicalUnitCount: Int
    var ownershipLexicalUnitCount: Int
    var alignmentLexicalUnitCount: Int
    var retryLexicalUnitCount: Int
    var finalLexicalUnitCount: Int

    enum CodingKeys: String, CodingKey {
        case trimmedHallucinatedSpanCount
        case rejectedAlignmentChunkCount
        case retriedAlignmentChunkCount
        case estimatedUnitCount
        case longestRejectedUnitDuration
        case removedDuplicatePrefixes
        case removedDuplicateSuffixes
        case removedContainedSpans
        case atomicSegmentFallbackCount
        case reconciledBoundaryCount
        case unresolvedBoundaryCount
        case retriedUncoveredRangeCount
        case retriedUncoveredSpeechSeconds
        case retriedUncoveredAcceptedCount
        case retriedUncoveredKeptFirstPassCount
        case rawLexicalUnitCount
        case qualityLexicalUnitCount
        case ownershipLexicalUnitCount
        case alignmentLexicalUnitCount
        case retryLexicalUnitCount
        case finalLexicalUnitCount
    }

    init(
        trimmedHallucinatedSpanCount: Int = 0,
        rejectedAlignmentChunkCount: Int = 0,
        retriedAlignmentChunkCount: Int = 0,
        estimatedUnitCount: Int = 0,
        longestRejectedUnitDuration: Double? = nil,
        removedDuplicatePrefixes: Int = 0,
        removedDuplicateSuffixes: Int = 0,
        removedContainedSpans: Int = 0,
        atomicSegmentFallbackCount: Int = 0,
        reconciledBoundaryCount: Int = 0,
        unresolvedBoundaryCount: Int = 0,
        retriedUncoveredRangeCount: Int = 0,
        retriedUncoveredSpeechSeconds: Double = 0,
        retriedUncoveredAcceptedCount: Int = 0,
        retriedUncoveredKeptFirstPassCount: Int = 0,
        rawLexicalUnitCount: Int = 0,
        qualityLexicalUnitCount: Int = 0,
        ownershipLexicalUnitCount: Int = 0,
        alignmentLexicalUnitCount: Int = 0,
        retryLexicalUnitCount: Int = 0,
        finalLexicalUnitCount: Int = 0
    ) {
        self.trimmedHallucinatedSpanCount = trimmedHallucinatedSpanCount
        self.rejectedAlignmentChunkCount = rejectedAlignmentChunkCount
        self.retriedAlignmentChunkCount = retriedAlignmentChunkCount
        self.estimatedUnitCount = estimatedUnitCount
        self.longestRejectedUnitDuration = longestRejectedUnitDuration
        self.removedDuplicatePrefixes = removedDuplicatePrefixes
        self.removedDuplicateSuffixes = removedDuplicateSuffixes
        self.removedContainedSpans = removedContainedSpans
        self.atomicSegmentFallbackCount = atomicSegmentFallbackCount
        self.reconciledBoundaryCount = reconciledBoundaryCount
        self.unresolvedBoundaryCount = unresolvedBoundaryCount
        self.retriedUncoveredRangeCount = retriedUncoveredRangeCount
        self.retriedUncoveredSpeechSeconds = retriedUncoveredSpeechSeconds
        self.retriedUncoveredAcceptedCount = retriedUncoveredAcceptedCount
        self.retriedUncoveredKeptFirstPassCount = retriedUncoveredKeptFirstPassCount
        self.rawLexicalUnitCount = rawLexicalUnitCount
        self.qualityLexicalUnitCount = qualityLexicalUnitCount
        self.ownershipLexicalUnitCount = ownershipLexicalUnitCount
        self.alignmentLexicalUnitCount = alignmentLexicalUnitCount
        self.retryLexicalUnitCount = retryLexicalUnitCount
        self.finalLexicalUnitCount = finalLexicalUnitCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trimmedHallucinatedSpanCount = try container.decodeIfPresent(Int.self, forKey: .trimmedHallucinatedSpanCount) ?? 0
        rejectedAlignmentChunkCount = try container.decodeIfPresent(Int.self, forKey: .rejectedAlignmentChunkCount) ?? 0
        retriedAlignmentChunkCount = try container.decodeIfPresent(Int.self, forKey: .retriedAlignmentChunkCount) ?? 0
        estimatedUnitCount = try container.decodeIfPresent(Int.self, forKey: .estimatedUnitCount) ?? 0
        longestRejectedUnitDuration = try container.decodeIfPresent(Double.self, forKey: .longestRejectedUnitDuration)
        removedDuplicatePrefixes = try container.decodeIfPresent(Int.self, forKey: .removedDuplicatePrefixes) ?? 0
        removedDuplicateSuffixes = try container.decodeIfPresent(Int.self, forKey: .removedDuplicateSuffixes) ?? 0
        removedContainedSpans = try container.decodeIfPresent(Int.self, forKey: .removedContainedSpans) ?? 0
        atomicSegmentFallbackCount = try container.decodeIfPresent(Int.self, forKey: .atomicSegmentFallbackCount) ?? 0
        reconciledBoundaryCount = try container.decodeIfPresent(Int.self, forKey: .reconciledBoundaryCount) ?? 0
        unresolvedBoundaryCount = try container.decodeIfPresent(Int.self, forKey: .unresolvedBoundaryCount) ?? 0
        retriedUncoveredRangeCount = try container.decodeIfPresent(Int.self, forKey: .retriedUncoveredRangeCount) ?? 0
        retriedUncoveredSpeechSeconds = try container.decodeIfPresent(Double.self, forKey: .retriedUncoveredSpeechSeconds) ?? 0
        retriedUncoveredAcceptedCount = try container.decodeIfPresent(Int.self, forKey: .retriedUncoveredAcceptedCount) ?? 0
        retriedUncoveredKeptFirstPassCount = try container.decodeIfPresent(Int.self, forKey: .retriedUncoveredKeptFirstPassCount) ?? 0
        rawLexicalUnitCount = try container.decodeIfPresent(Int.self, forKey: .rawLexicalUnitCount) ?? 0
        qualityLexicalUnitCount = try container.decodeIfPresent(Int.self, forKey: .qualityLexicalUnitCount) ?? 0
        ownershipLexicalUnitCount = try container.decodeIfPresent(Int.self, forKey: .ownershipLexicalUnitCount) ?? 0
        alignmentLexicalUnitCount = try container.decodeIfPresent(Int.self, forKey: .alignmentLexicalUnitCount) ?? 0
        retryLexicalUnitCount = try container.decodeIfPresent(Int.self, forKey: .retryLexicalUnitCount) ?? 0
        finalLexicalUnitCount = try container.decodeIfPresent(Int.self, forKey: .finalLexicalUnitCount) ?? 0
    }

    var completionDetail: String? {
        if estimatedUnitCount > 0 {
            return "\(estimatedUnitCount) word timings estimated"
        }
        if rejectedAlignmentChunkCount > 0 {
            return "alignment repaired"
        }
        if trimmedHallucinatedSpanCount > 0 {
            return "repeated ASR text removed"
        }
        if removedDuplicatePrefixes + removedDuplicateSuffixes + removedContainedSpans > 0 {
            return "ASR span ownership repaired"
        }
        if retriedUncoveredAcceptedCount > 0 {
            return "uncovered speech re-recognized"
        }
        return nil
    }

    var warning: String? {
        var parts: [String] = []
        if trimmedHallucinatedSpanCount > 0 {
            parts.append("removed repeated ASR text from \(trimmedHallucinatedSpanCount) span\(trimmedHallucinatedSpanCount == 1 ? "" : "s")")
        }
        if rejectedAlignmentChunkCount > 0 {
            parts.append("retried \(retriedAlignmentChunkCount) unstable alignment chunk\(retriedAlignmentChunkCount == 1 ? "" : "s")")
        }
        if estimatedUnitCount > 0 {
            parts.append("estimated \(estimatedUnitCount) word timing\(estimatedUnitCount == 1 ? "" : "s")")
        }
        if removedDuplicatePrefixes > 0 || removedDuplicateSuffixes > 0 || removedContainedSpans > 0 {
            parts.append(
                "resolved \(removedDuplicatePrefixes) duplicate prefix\(removedDuplicatePrefixes == 1 ? "" : "es"), \(removedDuplicateSuffixes) duplicate suffix\(removedDuplicateSuffixes == 1 ? "" : "es"), and \(removedContainedSpans) contained span\(removedContainedSpans == 1 ? "" : "s")"
            )
        }
        if retriedUncoveredAcceptedCount > 0 {
            let seconds = Int(retriedUncoveredSpeechSeconds.rounded())
            parts.append(
                "re-recognized \(retriedUncoveredAcceptedCount) uncovered speech range\(retriedUncoveredAcceptedCount == 1 ? "" : "s") (\(seconds)s)"
            )
        }
        return parts.isEmpty ? nil : "Transcript alignment \(parts.joined(separator: "; "))."
    }
}

struct TranscriptionDiagnosticsReport: Codable, Sendable {
    let diarization: DiarizationDiagnostics?
    let alignment: TranscriptionAlignmentDiagnostics?
}
