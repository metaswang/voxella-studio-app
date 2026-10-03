import Foundation

/// An atomic content patch shared by WorkbenchStore and isolated replay tooling.
/// Word indexes and authored text are stable; only affected source cues are rebuilt.
enum WorkbenchSpeakerBoundaryRepair {
    static func applying(to job: WorkbenchTranscriptionJob, words: [TranscriptionWord],
                         diagnostics: SpeakerBoundaryRefinementDiagnostics) -> WorkbenchTranscriptionJob? {
        guard job.translationTracks.isEmpty,
              let original = job.result, original.words.count == words.count,
              original.words.map(\.text) == words.map(\.text),
              words.allSatisfy({ word in
                  guard let start = word.start, let end = word.end else { return false }
                  return start.isFinite && end.isFinite && start >= 0 && end > start
              }) else { return nil }
        let changed = Set(words.indices.filter { words[$0] != original.words[$0] })
        guard !changed.isEmpty else { return job }
        var repaired = job
        repaired.result = TranscriptionResult(text: original.text, language: original.language, words: words,
                                             segments: TranscriptSegmenter.aggregate(words: words, language: original.language),
                                             asrEngine: original.asrEngine)
        if var track = job.subtitleTrack {
            guard track.usesWordTimestamps else { return nil }
            guard changed.allSatisfy({ id in track.cues.contains { $0.sourceIDs.contains(id) } }) else { return nil }
            var cues: [SubtitleCue] = []
            var nextID = (track.cues.map(\.id).max() ?? 0) + 1
            for cue in track.cues {
                guard cue.sourceIDs.contains(where: changed.contains) else { cues.append(cue); continue }
                guard !cue.sourceIDs.isEmpty, cue.sourceIDs.allSatisfy({ words.indices.contains($0) }) else { return nil }
                let source = cue.sourceIDs.map { original.words[$0].text }
                guard TranscriptSegmenter.joinedText(source, language: track.language) == cue.text else { return nil }
                var groups: [[Int]] = []
                for id in cue.sourceIDs {
                    if let last = groups.last?.last, words[last].speaker == words[id].speaker {
                        groups[groups.count - 1].append(id)
                    } else { groups.append([id]) }
                }
                for (index, ids) in groups.enumerated() {
                    var patched = cue
                    if index > 0 { patched.id = nextID; nextID += 1 }
                    patched.sourceIDs = ids
                    patched.text = TranscriptSegmenter.joinedText(ids.map { words[$0].text }, language: track.language)
                    patched.start = words[ids.first!].start!
                    patched.end = words[ids.last!].end!
                    patched.speaker = words[ids.first!].speaker
                    patched.timingQuality = .aggregate(ids.map { words[$0].timingQuality })
                    patched.boundaryBefore = words[ids.first!].speakerBoundary
                    patched.displayLineBreaks = nil
                    cues.append(patched)
                }
            }
            // Merge a repaired fragment into its contiguous same-speaker cue.
            var merged: [SubtitleCue] = []
            for cue in cues {
                if let last = merged.last, last.speaker != nil, last.speaker == cue.speaker,
                   (last.sourceIDs.contains(where: changed.contains) || cue.sourceIDs.contains(where: changed.contains)),
                   (isFragment(last) || isFragment(cue)),
                   let leftID = last.sourceIDs.last, let rightID = cue.sourceIDs.first, rightID == leftID + 1 {
                    var joined = last
                    joined.sourceIDs += cue.sourceIDs
                    joined.text = TranscriptSegmenter.joinedText([last.text, cue.text], language: track.language)
                    joined.end = cue.end
                    joined.displayLineBreaks = nil
                    joined.timingQuality = .aggregate(joined.sourceIDs.map { words[$0].timingQuality })
                    merged[merged.count - 1] = joined
                } else { merged.append(cue) }
            }
            track.cues = merged
            repaired.subtitleTrack = track
        }
        // Full transcript text and user-authored edit text remain byte-for-byte intact.
        var alignment = repaired.transcriptionAlignmentDiagnostics ?? .init()
        alignment.speakerBoundaryRefinement = diagnostics
        alignment.estimatedUnitCount = words.filter { $0.timingQuality == .estimated }.count
        repaired.transcriptionAlignmentDiagnostics = alignment
        return repaired
    }

    private static func isFragment(_ cue: SubtitleCue) -> Bool {
        cue.sourceIDs.count <= 2 && cue.end - cue.start <= 0.6
    }
}
