import SwiftUI

struct LibrarySelectionActionButtonStyle: ButtonStyle {
    enum Tone { case neutral, accent, destructive }
    var tone: Tone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, tone: tone)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let tone: Tone
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        private var tint: Color {
            switch tone {
            case .neutral: AppTheme.Text.secondaryColor
            case .accent: AppTheme.Accent.link
            case .destructive: AppTheme.Status.errorColor
            }
        }

        var body: some View {
            configuration.label
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(isEnabled ? tint : AppTheme.Text.mutedColor)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .frame(height: AppTheme.zoomed(32))
                .background {
                    Capsule()
                        .fill(tone == .neutral || !isEnabled
                            ? AppTheme.Background.raisedColor
                            : tint.opacity(AppTheme.Opacity.soft))
                        .overlay {
                            Capsule().fill(tint.opacity(isHovered && isEnabled ? AppTheme.Opacity.faint : 0))
                        }
                }
                .overlay {
                    Capsule().strokeBorder(
                        tone == .neutral || !isEnabled
                            ? AppTheme.Border.subtleColor
                            : tint.opacity(AppTheme.Opacity.moderate),
                        lineWidth: AppTheme.BorderWidth.thin
                    )
                }
                .opacity(isEnabled ? 1 : AppTheme.Opacity.strong)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isHovered)
                .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: configuration.isPressed)
        }
    }
}

struct LibrarySelectionIndicator: View {
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? AppTheme.Accent.link : Color.clear)
            Circle()
                .strokeBorder(
                    isSelected ? AppTheme.Accent.link : AppTheme.Text.mutedColor,
                    lineWidth: AppTheme.BorderWidth.medium
                )
            Image(systemName: "checkmark")
                .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected || reduceMotion ? 1 : 0.6)
        }
        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
        .accessibilityHidden(true)
    }
}
