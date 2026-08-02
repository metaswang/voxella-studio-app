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
            Text(tip.message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(foreground(for: tip.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if tip.actionLabel != nil {
                Button(tip.actionLabel ?? "") {
                    tips.performAction()
                }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(foreground(for: tip.kind))
                .underline()
            }

            Button {
                tips.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(foreground(for: tip.kind).opacity(AppTheme.Opacity.strong))
                    .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(background(for: tip.kind), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(border(for: tip.kind), lineWidth: AppTheme.BorderWidth.thin)
        }
        .shadow(AppTheme.Shadow.sm)
    }

    private func foreground(for kind: WorkbenchTipKind) -> Color {
        switch kind {
        case .success: AppTheme.Status.successColor
        case .error: AppTheme.Status.errorColor
        case .info: AppTheme.Status.infoColor
        }
    }

    private func background(for kind: WorkbenchTipKind) -> Color {
        foreground(for: kind).opacity(AppTheme.Opacity.soft)
    }

    private func border(for kind: WorkbenchTipKind) -> Color {
        foreground(for: kind).opacity(AppTheme.Opacity.muted)
    }
}
