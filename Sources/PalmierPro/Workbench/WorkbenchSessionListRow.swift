import SwiftUI

struct SessionListRow: View {
    let session: WorkbenchSession
    let onOpen: () -> Void
    let onDelete: () -> Void
    let allowsDelete: Bool

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: AppTheme.Spacing.lgXl) {
                WorkbenchSessionThumbnail(
                    session: session,
                    size: CGSize(
                        width: AppTheme.Workbench.recentSessionThumbnailWidth,
                        height: AppTheme.Workbench.recentSessionThumbnailHeight
                    ),
                    showsTypeBadge: true
                )
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(session.title)
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    HStack(spacing: AppTheme.Spacing.smMd) {
                        if session.sessionType.showsRecentListLabel {
                            Text(session.sessionType.label)
                        }
                        if let duration = session.duration {
                            Text(formatTime(duration))
                        }
                        Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                }
                Spacer(minLength: AppTheme.Spacing.zero)
                SessionPlacementIndicators(
                    storage: session.storage,
                    compute: session.compute,
                    showsLabel: true
                )
                SessionStatusBadge(state: session.state)
                Color.clear
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(AppTheme.Spacing.lgXl)
        .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sessionHeaderMinHeight, alignment: .leading)
        .background(
            isHovered ? AppTheme.Background.raisedColor : AppTheme.Background.surfaceColor,
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(
                    isHovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                    lineWidth: AppTheme.BorderWidth.thin
                )
        }
        .overlay(alignment: .trailing) {
            ZStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .opacity(isHovered ? AppTheme.Opacity.zero : AppTheme.Opacity.opaque)
                    .scaleEffect(isHovered ? 0.75 : 1)
                    .allowsHitTesting(false)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                        .background(
                            AppTheme.Status.errorColor.opacity(AppTheme.Opacity.soft),
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(
                                    AppTheme.Status.errorColor.opacity(AppTheme.Opacity.moderate),
                                    lineWidth: AppTheme.BorderWidth.thin
                                )
                        }
                }
                .buttonStyle(.plain)
                .help("Delete session")
                .disabled(!allowsDelete)
                .opacity(isHovered ? AppTheme.Opacity.opaque : AppTheme.Opacity.zero)
                .scaleEffect(isHovered ? 1 : 0.75)
                .allowsHitTesting(isHovered && allowsDelete)
            }
            .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
            .padding(.trailing, AppTheme.Spacing.lgXl)
        }
        .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}

struct SessionPlacementIndicators: View {
    let storage: TaskStorageDestination
    let compute: TaskComputeDestination
    var showsLabel = false

    private var hasCloudPlacement: Bool {
        storage == .cloud || compute == .cloud
    }

    private var placementLabel: String {
        switch (storage, compute) {
        case (.local, .local):
            TaskPlacementCopy.thisMac
        case (.cloud, .cloud):
            TaskPlacementCopy.voxStudioCloud
        case (.cloud, .local):
            "Cloud session"
        case (.local, .cloud):
            "Cloud processing"
        }
    }

    private var placementHelp: String {
        "\(TaskPlacementCopy.storageTooltip(for: storage)) · \(TaskPlacementCopy.computeTooltip(for: compute))"
    }

    var body: some View {
        HStack(spacing: showsLabel ? AppTheme.Spacing.xs : AppTheme.Spacing.md) {
            Image(systemName: storage == .local ? "internaldrive" : "icloud")
                .accessibilityLabel(TaskPlacementCopy.storageTooltip(for: storage))
                .help(TaskPlacementCopy.storageTooltip(for: storage))
            Image(systemName: compute == .local ? "laptopcomputer" : "cloud")
                .accessibilityLabel(TaskPlacementCopy.computeTooltip(for: compute))
                .help(TaskPlacementCopy.computeTooltip(for: compute))
            if showsLabel {
                Text(placementLabel)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .lineLimit(1)
            }
        }
        .font(.system(size: AppTheme.FontSize.sm))
        .foregroundStyle(
            hasCloudPlacement
                ? AppTheme.Accent.link
                : AppTheme.Text.tertiaryColor
        )
        .padding(.horizontal, showsLabel ? AppTheme.Spacing.smMd : AppTheme.Spacing.zero)
        .padding(.vertical, showsLabel ? AppTheme.Spacing.xs : AppTheme.Spacing.zero)
        .background(
            showsLabel
                ? (hasCloudPlacement
                    ? AppTheme.Accent.link.opacity(AppTheme.Opacity.soft)
                    : AppTheme.Background.raisedColor)
                : Color.clear,
            in: Capsule()
        )
        .overlay {
            if showsLabel {
                Capsule()
                    .strokeBorder(
                        hasCloudPlacement
                            ? AppTheme.Accent.link.opacity(AppTheme.Opacity.moderate)
                            : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            }
        }
        .help(showsLabel ? placementHelp : "")
        .accessibilityElement(children: .contain)
    }
}

struct SessionStatusBadge: View {
    let state: WorkbenchJobState

    var body: some View {
        Label(state.label, systemImage: systemImage)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(color)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(color.opacity(AppTheme.Opacity.soft), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .completed: AppTheme.Status.successColor
        case .failed: AppTheme.Status.errorColor
        case .running, .cancelling: AppTheme.Status.warningColor
        case .ready, .cancelled: AppTheme.Text.tertiaryColor
        }
    }

    private var systemImage: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .running, .cancelling: "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready: "circle"
        case .cancelled: "xmark.circle"
        }
    }
}
