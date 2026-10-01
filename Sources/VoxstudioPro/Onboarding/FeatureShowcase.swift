import AppKit
import SwiftUI

struct FeatureShowcase: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = FeatureWallPlayback()

    var body: some View {
        GeometryReader { geometry in
            SwiftUI.TimelineView(.animation(minimumInterval: AppTheme.Anim.showcaseFrameInterval, paused: !playback.isRunning)) { context in
                let time = playback.elapsed(at: context.date)
                ZStack {
                    AppTheme.Onboarding.canvas
                    ForEach(0..<10) { card in
                        let column = card / 5
                        let index = card % 5
                        let y = FeatureWallMotion.position(
                            index: index, count: 5, pitch: AppTheme.Onboarding.cardPitch,
                            elapsed: time, speed: (column == 0 ? -1 : 1) * AppTheme.Anim.showcasePointsPerSecond,
                            offset: column == 0 ? 0 : AppTheme.Onboarding.columnOffset
                        )
                        let emphasis = reduceMotion ? 0 : FeatureWallMotion.prominence(
                            y: y, center: geometry.size.height / 2, radius: AppTheme.Onboarding.focalRadius
                        )
                        FeatureWallCard(kind: (index + column * 3) % 6)
                            .frame(width: AppTheme.Onboarding.cardWidth)
                            .rotationEffect(.degrees((index.isMultiple(of: 2) ? -1 : 1) * AppTheme.Onboarding.cardTilt * (1 - emphasis)))
                            .scaleEffect(
                                FeatureWallMotion.scale(y: y, center: geometry.size.height / 2, reduceMotion: reduceMotion),
                                anchor: column == 0 ? .leading : .trailing
                            )
                            .position(
                                x: column == 0
                                    ? AppTheme.Onboarding.laneInset + AppTheme.Onboarding.cardWidth / 2
                                    : geometry.size.width - AppTheme.Onboarding.laneInset - AppTheme.Onboarding.cardWidth / 2,
                                y: y
                            )
                            .zIndex(emphasis)
                    }
                }
                .drawingGroup()
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: AppTheme.Onboarding.fadeEdge),
                    .init(color: .black, location: 1 - AppTheme.Onboarding.fadeEdge),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
        }
        .background(AppTheme.Onboarding.canvas)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if !reduceMotion {
                Button { playback.togglePause() } label: {
                    Image(systemName: playback.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .padding(AppTheme.Spacing.md)
                        .background(AppTheme.Onboarding.paper, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Onboarding.ink)
                .accessibilityLabel(L10n.string(playback.isPaused ? "Resume animation" : "Pause animation"))
                .padding(AppTheme.Spacing.lg)
            }
        }
        .onAppear {
            playback.appear(applicationActive: NSApplication.shared.isActive, reduceMotion: reduceMotion)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            playback.setApplicationActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            playback.setApplicationActive(false)
        }
        .onChange(of: reduceMotion) { _, reduced in playback.setReduceMotion(reduced) }
        .onDisappear { playback.disappear() }
    }
}

private struct FeatureWallCard: View {
    let kind: Int

    private var tint: Color {
        switch kind {
        case 1, 4: AppTheme.Onboarding.mint
        case 2, 5: AppTheme.Onboarding.coral
        default: AppTheme.Onboarding.ink
        }
    }

    private var title: String {
        switch kind {
        case 0: "Every word, captured."
        case 1: "Your words. Your voice."
        case 2: "Find that moment."
        case 3: "A story in the making."
        case 4: "Beyond one language."
        default: "Press record. Be present."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Image(systemName: ["captions.bubble", "waveform", "sparkle.magnifyingglass", "film.stack", "character.bubble", "record.circle"][kind])
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .opacity(AppTheme.Opacity.medium)
            }
            Text(L10n.string(title))
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .fixedSize(horizontal: false, vertical: true)
            illustration
        }
        .foregroundStyle(tint)
        .padding(AppTheme.Spacing.lgXl)
        .frame(maxWidth: .infinity, minHeight: kind.isMultiple(of: 2) ? AppTheme.Onboarding.cardHeight : AppTheme.Onboarding.smallCardHeight, alignment: .leading)
        .background(AppTheme.Onboarding.paper, in: RoundedRectangle(cornerRadius: kind == 1 ? AppTheme.Radius.xl : AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: kind == 1 ? AppTheme.Radius.xl : AppTheme.Radius.lg)
                .strokeBorder(tint.opacity(AppTheme.Opacity.faint), lineWidth: AppTheme.BorderWidth.thin)
        }
        .compositingGroup()
        .shadow(AppTheme.Shadow.sm)
    }

    @ViewBuilder private var illustration: some View {
        switch kind {
        case 0:
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("00:12 — 00:16").font(.system(size: AppTheme.FontSize.xxs).monospacedDigit())
                Text(L10n.string("It started with an idea."))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .padding(AppTheme.Spacing.smMd)
                    .background(tint.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
        case 1, 5:
            HStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(0..<24) { index in
                    Capsule()
                        .fill(tint.opacity(index.isMultiple(of: 3) ? AppTheme.Opacity.prominent : AppTheme.Opacity.muted))
                        .frame(width: AppTheme.Onboarding.waveBarWidth, height: AppTheme.Onboarding.waveHeight * (0.2 + abs(sin(Double(index) * 1.7)) * 0.8))
                }
            }
        case 2:
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                Text(L10n.string("The next big idea…"))
                    .font(.system(size: AppTheme.FontSize.sm))
            }
            .padding(AppTheme.Spacing.md)
            .background(tint.opacity(AppTheme.Opacity.subtle), in: Capsule())
        case 3:
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    ForEach(0..<3) { index in
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .fill(tint.opacity(index == 1 ? AppTheme.Opacity.prominent : AppTheme.Opacity.muted))
                            .frame(height: AppTheme.IconSize.md)
                            .overlay { Image(systemName: "play.fill").font(.system(size: AppTheme.FontSize.micro)).foregroundStyle(AppTheme.Onboarding.paper) }
                    }
                }
                Capsule().fill(AppTheme.Onboarding.mint.opacity(AppTheme.Opacity.medium)).frame(height: AppTheme.Spacing.sm)
            }
        default:
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Hello").font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.medium))
                Image(systemName: "arrow.right")
                Text("你好").font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.medium))
            }
        }
    }
}
