import AVFoundation
import SwiftUI

struct ClipRangeControl: View {
    let mediaURL: URL
    @Binding var range: ClosedRange<Double>
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var endObserver: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.indigo, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(duration <= 0)

                SwiftUI.TimelineView(.periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)) { _ in
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let timelineDuration = max(duration, 0.001)
                        let rawPlayhead = player?.currentTime().seconds ?? range.lowerBound
                        let playhead = rawPlayhead.isFinite
                            ? min(max(0, rawPlayhead), duration)
                            : range.lowerBound
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AppTheme.Background.raisedColor)
                            Capsule()
                                .fill(Color.indigo.opacity(0.35))
                                .frame(width: max(2, width * CGFloat((range.upperBound - range.lowerBound) / timelineDuration)))
                                .offset(x: width * CGFloat(range.lowerBound / timelineDuration))
                            playbackMarker(at: playhead, width: width)
                            handle(at: range.lowerBound, width: width) { value in
                                let clamped = min(max(0, value), range.upperBound - 0.25)
                                range = clamped...range.upperBound
                            }
                            handle(at: range.upperBound, width: width) { value in
                                let clamped = max(min(duration, value), range.lowerBound + 0.25)
                                range = range.lowerBound...clamped
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let seconds = Double(value.location.x / width) * duration
                                    let mid = (range.lowerBound + range.upperBound) / 2
                                    let half = (range.upperBound - range.lowerBound) / 2
                                    if abs(seconds - range.lowerBound) < abs(seconds - range.upperBound) {
                                        range = min(max(0, seconds), range.upperBound - 0.25)...range.upperBound
                                    } else if abs(seconds - range.upperBound) <= abs(seconds - mid) {
                                        range = range.lowerBound...max(min(duration, seconds), range.lowerBound + 0.25)
                                    } else {
                                        let start = min(max(0, seconds - half), duration - 2 * half)
                                        range = start...(start + 2 * half)
                                    }
                                }
                        )
                    }
                }
                .frame(height: 28)
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
        .task(id: mediaURL) { await loadDuration() }
        .onDisappear { stopPlayback() }
    }

    private func handle(at seconds: Double, width: CGFloat, onDrag: @escaping (Double) -> Void) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .offset(x: width * CGFloat(seconds / max(duration, 0.001)) - 7)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDrag(Double(value.location.x / max(width, 1)) * duration)
                    }
            )
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
        .offset(x: width * CGFloat(seconds / max(duration, 0.001)) - AppTheme.Spacing.md / 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func loadDuration() async {
        let asset = AVURLAsset(url: mediaURL)
        do {
            let cmDuration = try await asset.load(.duration)
            let seconds = cmDuration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            duration = seconds
            if range.upperBound <= range.lowerBound || range.upperBound > seconds {
                range = 0...seconds
            }
        } catch {
            duration = 0
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        let item = AVPlayerItem(url: mediaURL)
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.seek(to: CMTime(seconds: range.lowerBound, preferredTimescale: 600))
        player.play()
        isPlaying = true
        let endSeconds = range.upperBound
        endObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak player] time in
            if time.seconds >= endSeconds {
                player?.pause()
            }
        }
    }

    private func stopPlayback() {
        if let endObserver, let player {
            player.removeTimeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
