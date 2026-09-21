import SwiftUI

struct WorkbenchTopTipBanner: View {
    @Bindable private var tips = WorkbenchTipCenter.shared

    var body: some View {
        if let tip = tips.tip {
            banner(tip)
                .padding(.horizontal, AppTheme.Workbench.tipHorizontalInset)
                .padding(.vertical, AppTheme.Workbench.tipVerticalInset)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    )
                )
        }
    }

    private func banner(_ tip: WorkbenchTip) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            Image(systemName: symbol(for: tip.kind))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(foreground(for: tip.kind))
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)

            Text(L10n.display(tip.message))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(foreground(for: tip.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if tip.actionLabel != nil {
                Button(L10n.display(tip.actionLabel ?? "")) {
                    tips.performAction()
                }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(foreground(for: tip.kind))
                .underline()
            }

            Button(L10n.string("Dismiss")) {
                tips.hide()
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(foreground(for: tip.kind))
            .help(L10n.string("Dismiss"))
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .fill(background(for: tip.kind))
                .shadow(AppTheme.Shadow.sm)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(border(for: tip.kind), lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private func foreground(for kind: WorkbenchTipKind) -> Color {
        switch kind {
        case .success: AppTheme.Status.successColor
        case .warning: AppTheme.Status.warningColor
        case .error: AppTheme.Status.errorColor
        case .info: AppTheme.Status.infoColor
        }
    }

    private func symbol(for kind: WorkbenchTipKind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    private func background(for kind: WorkbenchTipKind) -> Color {
        foreground(for: kind).opacity(AppTheme.Opacity.soft)
    }

    private func border(for kind: WorkbenchTipKind) -> Color {
        foreground(for: kind).opacity(AppTheme.Opacity.muted)
    }
}
