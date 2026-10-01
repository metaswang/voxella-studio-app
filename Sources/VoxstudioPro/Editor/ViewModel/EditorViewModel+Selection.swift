extension EditorViewModel {
    enum SelectForwardScope {
        case track
        case allTracks
    }

    func selectPreviewClip(_ clipId: String) {
        selectedGap = nil
        guard !selectedClipIds.contains(clipId) else { return }
        selectedClipIds = expandToLinkGroup([clipId])
    }

    /// Any non-empty track exposes header click to select or clear every clip on it.
    func supportsPartsSelection(on trackIndex: Int) -> Bool {
        guard timeline.tracks.indices.contains(trackIndex) else { return false }
        return !timeline.tracks[trackIndex].clips.isEmpty
    }

    func isTrackPartsFullySelected(at trackIndex: Int) -> Bool {
        guard supportsPartsSelection(on: trackIndex) else { return false }
        let ids = timeline.tracks[trackIndex].clips.map(\.id)
        return ids.allSatisfy { selectedClipIds.contains($0) }
    }

    /// Toggle selection of every clip on the track.
    func toggleSelectAllClips(onTrackIndex trackIndex: Int) {
        guard supportsPartsSelection(on: trackIndex) else { return }
        let ids = Set(timeline.tracks[trackIndex].clips.map(\.id))
        if ids.isSubset(of: selectedClipIds) {
            selectedClipIds.subtract(ids)
        } else {
            selectedClipIds = ids
        }
        selectedGap = nil
        selectedTimelineRange = nil
    }

    func selectForwardFromCurrentSelection(scope: SelectForwardScope) {
        guard let anchorId = forwardSelectionAnchorId() else { return }
        selectForward(from: anchorId, scope: scope)
    }

    func selectForward(from clipId: String, scope: SelectForwardScope) {
        guard let anchorLoc = findClip(id: clipId) else { return }
        let anchorClip = timeline.tracks[anchorLoc.trackIndex].clips[anchorLoc.clipIndex]
        var ids: Set<String> = []

        for (trackIndex, track) in timeline.tracks.enumerated() {
            guard scope == .allTracks || trackIndex == anchorLoc.trackIndex else { continue }
            for clip in track.clips where clip.startFrame >= anchorClip.startFrame {
                ids.insert(clip.id)
            }
        }

        selectedClipIds = expandToLinkGroup(ids)
        selectedGap = nil
        selectedTimelineRange = nil
    }

    private func forwardSelectionAnchorId() -> String? {
        timeline.tracks.enumerated()
            .flatMap { trackIndex, track in
                track.clips
                    .filter { selectedClipIds.contains($0.id) }
                    .map { (trackIndex: trackIndex, clip: $0) }
            }
            .sorted {
                if $0.clip.startFrame == $1.clip.startFrame {
                    return $0.trackIndex < $1.trackIndex
                }
                return $0.clip.startFrame < $1.clip.startFrame
            }
            .first?
            .clip
            .id
    }
}
