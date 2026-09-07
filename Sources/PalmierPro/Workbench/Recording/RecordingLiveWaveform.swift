import Foundation
import SwiftUI

final class RecordingLiveWaveformStore: @unchecked Sendable {
    static let capacity = 160
    static let barInterval: TimeInterval = 0.036

    private let lock = NSLock()
    private var bars: [Float]
    private var nextBarTime: TimeInterval?
    private var pendingPeak: Float = 0
    private var isPaused = false

    init() {
        bars = Array(repeating: 0, count: Self.capacity)
    }

    func reset() {
        lock.lock()
        bars = Array(repeating: 0, count: Self.capacity)
        nextBarTime = nil
        pendingPeak = 0
        isPaused = false
        lock.unlock()
    }

    func pause() {
        lock.lock()
        isPaused = true
        lock.unlock()
    }

    func resume(at time: TimeInterval) {
        lock.lock()
        isPaused = false
        if nextBarTime != nil {
            nextBarTime = time + Self.barInterval
        }
        pendingPeak = 0
        lock.unlock()
    }

    func ingest(peak: Float, at time: TimeInterval) {
        let clamped = min(1, max(0, peak.isFinite ? peak : 0))
        lock.lock()
        defer { lock.unlock() }
        guard !isPaused else { return }
        advanceLocked(to: time, incomingPeak: clamped)
    }

    func snapshot(at time: TimeInterval) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if !isPaused {
            advanceLocked(to: time, incomingPeak: 0)
        }
        return bars
    }

    private func advanceLocked(to time: TimeInterval, incomingPeak: Float) {
        guard let next = nextBarTime else {
            nextBarTime = time + Self.barInterval
            pendingPeak = incomingPeak
            return
        }
        if time + Self.barInterval < next {
            nextBarTime = time + Self.barInterval
            pendingPeak = incomingPeak
            return
        }
        if time - next > 1 {
            nextBarTime = time + Self.barInterval
            pendingPeak = incomingPeak
            return
        }

        var cursor = next
        while time >= cursor {
            pushLocked(pendingPeak)
            pendingPeak = 0
            cursor += Self.barInterval
        }
        pendingPeak = max(pendingPeak, incomingPeak)
        nextBarTime = cursor
    }

    private func pushLocked(_ peak: Float) {
        bars.removeFirst()
        bars.append(min(1, max(0, peak)))
    }
}

struct RecordingLiveWaveformView: View {
    let store: RecordingLiveWaveformStore
    let isPaused: Bool

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: AppTheme.Workbench.recordingWaveformRefreshInterval)) { _ in
            RecordingLiveWaveformCanvas(
                samples: store.snapshot(at: ProcessInfo.processInfo.systemUptime),
                isPaused: isPaused
            )
        }
        .frame(height: AppTheme.Workbench.recordingWaveformHeight)
        .accessibilityLabel("Recording waveform")
        .accessibilityValue(isPaused ? "Paused" : "Live")
        .allowsHitTesting(false)
    }
}

private struct RecordingLiveWaveformCanvas: View {
    let samples: [Float]
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let barWidth = AppTheme.Workbench.recordingWaveformBarWidth
            let spacing = AppTheme.Workbench.recordingWaveformBarSpacing
            let step = barWidth + spacing
            let count = min(samples.count, max(1, Int((size.width + spacing) / step)))
            let visible = samples.suffix(count)
            let totalWidth = CGFloat(visible.count) * step - spacing
            let startX = max(0, size.width - totalWidth)
            let midY = size.height / 2
            let color = isPaused ? AppTheme.Status.warningColor : AppTheme.Text.primaryColor
            let lastIndex = max(0, visible.count - 1)

            for (offset, peak) in visible.enumerated() {
                let amplitude = Self.displayAmplitude(peak)
                let height = max(
                    AppTheme.Workbench.recordingWaveformMinimumBarHeight,
                    size.height * amplitude
                )
                let rect = CGRect(
                    x: startX + CGFloat(offset) * step,
                    y: midY - height / 2,
                    width: barWidth,
                    height: height
                )
                let age = lastIndex == 0 ? 1 : Double(offset) / Double(lastIndex)
                let opacity = isPaused
                    ? AppTheme.Opacity.medium
                    : AppTheme.Opacity.moderate + (AppTheme.Opacity.prominent - AppTheme.Opacity.moderate) * age
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(color.opacity(opacity)))
            }

            if !isPaused, size.height > 0 {
                let marker = CGRect(
                    x: size.width - AppTheme.BorderWidth.thin,
                    y: AppTheme.Spacing.xxs,
                    width: AppTheme.BorderWidth.thin,
                    height: size.height - AppTheme.Spacing.xs
                )
                context.fill(
                    Path(roundedRect: marker, cornerRadius: AppTheme.Radius.xs),
                    with: .color(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.medium))
                )
            }
        }
    }

    private static func displayAmplitude(_ peak: Float) -> CGFloat {
        let floor = AppTheme.Workbench.recordingWaveformFloorDb
        let ceiling = AppTheme.Workbench.recordingWaveformCeilingDb
        let range = ceiling - floor
        guard range > 0 else { return 0 }
        let decibels: Float = peak > 0 ? 20 * log10(peak) : floor
        let normalized = (min(ceiling, max(floor, decibels)) - floor) / range
        return CGFloat(normalized)
    }
}
