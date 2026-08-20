import SwiftUI

struct EditorActionFooter<Actions: View>: View {
    let message: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let message {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.thin)
        }
    }
}
