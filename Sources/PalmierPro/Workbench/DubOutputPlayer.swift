import SwiftUI

struct DubOutputPlayer: View {
    let url: URL
    let onPlaybackStart: () -> Void

    @State private var playback = SessionPlaybackController()

    var body: some View {
        SwiftUI.TimelineView(
            .periodic(from: .now, by: AppTheme.Workbench.playerRefreshInterval)
        ) { _ in
            let currentTime = playback.player?.currentTime().seconds.finiteOrZero ?? 0
            let duration = playback.duration
            let progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            let remaining = max(0, duration - currentTime)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                AudioWaveformView(peaks: playback.peaks, progress: progress)
                    .frame(height: AppTheme.Workbench.waveformHeight)

                Slider(
                    value: Binding(
                        get: { progress },
                        set: { value in
                            playback.seek(
                                to: value,
                                resumesPlayback: playback.isPlaying
                            )
                        }
                    ),
                    in: 0...1
                )
                .disabled(playback.player == nil || duration <= 0)

                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(formatTime(currentTime))
                    Spacer(minLength: 0)
                    Text("-\(formatTime(remaining))")
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Text(formatTime(duration))
                }
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

                HStack(spacing: AppTheme.Spacing.smMd) {
                    Button {
                        playback.seekBy(
                            -AppTheme.Workbench.dubSeekStepSeconds,
                            resumesPlayback: playback.isPlaying
                        )
                    } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .buttonStyle(.borderless)
                    .help("Rewind \(Int(AppTheme.Workbench.dubSeekStepSeconds)) seconds")
                    .disabled(playback.player == nil)

                    Button {
                        onPlaybackStart()
                        if !playback.isPlaying {
                            AudioPlaybackCoordinator.shared.begin(id: url.absoluteString) { [weak playback] in
                                playback?.stop()
                            }
                        }
                        playback.togglePlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(playback.player == nil)
                    .help(playback.isPlaying ? "Pause" : "Play")

                    Button {
                        playback.seekBy(
                            AppTheme.Workbench.dubSeekStepSeconds,
                            resumesPlayback: playback.isPlaying
                        )
                    } label: {
                        Image(systemName: "goforward.10")
                    }
                    .buttonStyle(.borderless)
                    .help("Forward \(Int(AppTheme.Workbench.dubSeekStepSeconds)) seconds")
                    .disabled(playback.player == nil)

                    Spacer(minLength: 0)

                    Menu {
                        ForEach(AppTheme.Workbench.playbackRates, id: \.self) { rate in
                            Button {
                                playback.setPlaybackRate(rate)
                            } label: {
                                HStack {
                                    Text(rateLabel(rate))
                                    if abs(playback.playbackRate - rate) < 0.001 {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(rateLabel(playback.playbackRate))
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(playback.player == nil)
                    .help("Playback speed")
                }
            }
        }
        .task(id: url) {
            await playback.load(url: url, showsVideoCanvas: false)
        }
        .onDisappear {
            playback.tearDown()
            AudioPlaybackCoordinator.shared.end(id: url.absoluteString)
        }
    }

    private func rateLabel(_ rate: Double) -> String {
        if abs(rate - 1) < 0.001 { return "1×" }
        if rate == Double(Int(rate)) { return "\(Int(rate))×" }
        return String(format: "%.2g×", rate)
    }
}
