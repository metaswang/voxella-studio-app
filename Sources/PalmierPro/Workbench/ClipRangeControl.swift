import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
private final class ClipRangePlayback {
    var player: AVPlayer?
    var isPlaying = false
    var playheadSeconds = 0.0

    private var endObserver: Any?
    private var seekGeneration = UUID()
    private var installedURL: URL?

    func install(url: URL, at seconds: Double) {
        if installedURL != url {
            clearObserver()
            player = AVPlayer(playerItem: AVPlayerItem(url: url))
            installedURL = url
        }
        seek(to: seconds, resume: false)
    }

    func seek(to seconds: Double, resume: Bool, playUntil endSeconds: Double? = nil, rangeStart: Double? = nil) {
        guard let player else { return }
        let generation = UUID()
        seekGeneration = generation
        playheadSeconds = seconds
        player.pause()
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: AppTheme.Workbench.playerTimescale),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation, completed else { return }
                self.playheadSeconds = player.currentTime().seconds.finiteOrZero
                if resume, let endSeconds, let rangeStart {
                    self.play(until: endSeconds, rangeStart: rangeStart)
                } else if resume {
                    player.play()
                    self.isPlaying = true
                }
            }
        }
        if !resume {
            player.pause()
            isPlaying = false
        }
    }

    func play(until endSeconds: Double, rangeStart: Double) {
        guard let player else { return }
        clearObserver()
        player.play()
        isPlaying = true
        endObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(
                seconds: AppTheme.Workbench.playerRefreshInterval,
                preferredTimescale: AppTheme.Workbench.playerTimescale
            ),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = time.seconds
                guard current.isFinite else { return }
                self.playheadSeconds = min(max(rangeStart, current), endSeconds)
                if current >= endSeconds - AppTheme.Workbench.playerEndTolerance {
                    self.pause()
                    self.playheadSeconds = endSeconds
                }
            }
        }
    }

    func pause() {
        clearObserver()
        player?.pause()
        isPlaying = false
    }

    func tearDown() {
        pause()
        player = nil
        installedURL = nil
    }

    private func clearObserver() {
        if let endObserver, let player {
            player.removeTimeObserver(endObserver)
        }
        endObserver = nil
    }
}

struct ClipRangeControl: View {
    let mediaURL: URL
    @Binding var range: ClosedRange<Double>

    @State private var duration: Double = 0
    @State private var playback = ClipRangePlayback()
    @State private var dragTarget: DragTarget?
    @State private var dragOriginRange: ClosedRange<Double>?
    @State private var moveGrabOffset = 0.0
    @State private var isVideo = false
    @State private var playbackURL: URL?

    private enum DragTarget {
        case playhead
        case startHandle
        case endHandle
        case moveRange
    }

    private var timelineDuration: Double { max(duration, 0.001) }
    private var minimumRange: Double { min(0.25, timelineDuration) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if isVideo {
                videoPreview
            }

            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(.white)
                        .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                        .background(AppTheme.Accent.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(duration <= 0)

                timeline
                    .frame(height: AppTheme.Workbench.clipTimelineHeight)
            }

            HStack {
                Text("Start: \(formatClock(range.lowerBound))")
                Spacer()
                Text("End: \(formatClock(range.upperBound))")
                Spacer()
                Text("Len: \(formatClock(range.upperBound - range.lowerBound))")
            }
            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
            .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .task(id: mediaURL) {
            await prepareMedia()
        }
        .onChange(of: range) { _, newRange in
            clampPlayhead(to: newRange)
        }
        .onDisappear { playback.tearDown() }
    }

    private var videoPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(Color.black)
            if let player = playback.player {
                SessionAVPlayerRepresentable(player: player)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: AppTheme.Workbench.clipPreviewMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .accessibilityLabel("Clip preview")
    }

    private var timeline: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)) { _ in
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let displayedPlayhead = displayedPlayheadSeconds()
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppTheme.Background.raisedColor)
                    Capsule()
                        .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium))
                        .frame(width: max(2, width * CGFloat((range.upperBound - range.lowerBound) / timelineDuration)))
                        .offset(x: width * CGFloat(range.lowerBound / timelineDuration))
                    handleKnob(at: range.lowerBound, width: width)
                    handleKnob(at: range.upperBound, width: width)
                    playbackMarker(at: displayedPlayhead, width: width)
                }
                .contentShape(Rectangle())
                .gesture(timelineDragGesture(width: width))
            }
        }
    }

    private func timelineDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let seconds = seconds(at: value.location.x, width: width)
                if dragTarget == nil {
                    dragTarget = resolveDragTarget(
                        at: seconds,
                        y: value.location.y,
                        width: width,
                        height: AppTheme.Workbench.clipTimelineHeight
                    )
                    dragOriginRange = range
                    if dragTarget == .moveRange {
                        moveGrabOffset = seconds - range.lowerBound
                    }
                    playback.pause()
                }
                applyDrag(seconds: seconds)
            }
            .onEnded { _ in
                dragTarget = nil
                dragOriginRange = nil
            }
    }

    private func resolveDragTarget(
        at seconds: Double,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> DragTarget {
        let hitSeconds = Double(AppTheme.Workbench.clipHandleHitWidth / max(width, 1)) * timelineDuration
        let playhead = displayedPlayheadSeconds()
        let nearPlayhead = abs(seconds - playhead) <= hitSeconds
        let nearStart = abs(seconds - range.lowerBound) <= hitSeconds
        let nearEnd = abs(seconds - range.upperBound) <= hitSeconds
        // Upper area is the playhead head; lower area keeps handle grabs when overlapping.
        let prefersPlayheadBand = y < height * 0.55

        if nearPlayhead, prefersPlayheadBand || (!nearStart && !nearEnd) {
            return .playhead
        }
        if nearStart {
            return .startHandle
        }
        if nearEnd {
            return .endHandle
        }
        if nearPlayhead {
            return .playhead
        }
        if seconds >= range.lowerBound, seconds <= range.upperBound {
            return .moveRange
        }
        return .playhead
    }

    private func applyDrag(seconds: Double) {
        switch dragTarget {
        case .playhead, .none:
            let clamped = min(max(range.lowerBound, seconds), range.upperBound)
            playback.seek(to: clamped, resume: false)
        case .startHandle:
            let clamped = min(max(0, seconds), range.upperBound - minimumRange)
            range = clamped...range.upperBound
            if playback.playheadSeconds < clamped {
                playback.seek(to: clamped, resume: false)
            }
        case .endHandle:
            let clamped = max(min(duration, seconds), range.lowerBound + minimumRange)
            range = range.lowerBound...clamped
            if playback.playheadSeconds > clamped {
                playback.seek(to: clamped, resume: false)
            }
        case .moveRange:
            guard let origin = dragOriginRange else { return }
            let span = origin.upperBound - origin.lowerBound
            let start = min(max(0, seconds - moveGrabOffset), max(0, duration - span))
            range = start...(start + span)
            let clampedPlayhead = min(max(range.lowerBound, playback.playheadSeconds), range.upperBound)
            playback.seek(to: clampedPlayhead, resume: false)
        }
    }

    private func handleKnob(at seconds: Double, width: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .frame(width: AppTheme.Workbench.clipHandleSize, height: AppTheme.Workbench.clipHandleSize)
            .shadow(color: .black.opacity(AppTheme.Opacity.medium), radius: 2, y: 1)
            .offset(x: width * CGFloat(seconds / timelineDuration) - AppTheme.Workbench.clipHandleSize / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func playbackMarker(at seconds: Double, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(AppTheme.Accent.primary)
                .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)
            Rectangle()
                .fill(AppTheme.Accent.primary)
                .frame(width: AppTheme.BorderWidth.medium, height: AppTheme.Spacing.lgXl)
        }
        .frame(width: AppTheme.Spacing.md, height: AppTheme.Spacing.xxl)
        .offset(x: width * CGFloat(seconds / timelineDuration) - AppTheme.Spacing.md / 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func prepareMedia() async {
        isVideo = UTType(filenameExtension: mediaURL.pathExtension)?.conforms(to: .movie) == true
        playback.tearDown()
        let resolvedURL: URL
        if isVideo {
            resolvedURL = mediaURL
        } else {
            resolvedURL = (try? await DecodedAudioCache.file(for: mediaURL)) ?? mediaURL
        }
        playbackURL = resolvedURL
        let asset = AVURLAsset(url: resolvedURL)
        do {
            let cmDuration = try await asset.load(.duration)
            let seconds = cmDuration.seconds
            guard seconds.isFinite, seconds > 0 else {
                duration = 0
                return
            }
            duration = seconds
            if range.upperBound <= range.lowerBound || range.upperBound > seconds {
                range = 0...seconds
            }
            playback.install(url: resolvedURL, at: range.lowerBound)
        } catch {
            duration = 0
        }
    }

    private func togglePlayback() {
        if playback.isPlaying {
            playback.pause()
            return
        }
        let startAt = playback.playheadSeconds < range.upperBound - AppTheme.Workbench.playerEndTolerance
            ? playback.playheadSeconds
            : range.lowerBound
        let url = playbackURL ?? mediaURL
        playback.install(url: url, at: startAt)
        playback.seek(to: startAt, resume: true, playUntil: range.upperBound, rangeStart: range.lowerBound)
    }

    private func clampPlayhead(to newRange: ClosedRange<Double>) {
        let clamped = min(max(newRange.lowerBound, playback.playheadSeconds), newRange.upperBound)
        if abs(clamped - playback.playheadSeconds) > 0.001 {
            playback.seek(to: clamped, resume: false)
        }
    }

    private func displayedPlayheadSeconds() -> Double {
        if playback.isPlaying, let current = playback.player?.currentTime().seconds, current.isFinite {
            return min(max(range.lowerBound, current), range.upperBound)
        }
        return min(max(range.lowerBound, playback.playheadSeconds), range.upperBound)
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(0, x), width) / max(width, 1)) * timelineDuration
    }

    private func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
