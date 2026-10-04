import SwiftUI

struct SessionListRow: View {
    let session: WorkbenchSession
    let onOpen: () -> Void
    let onDelete: () -> Void
    let allowsDelete: Bool
    var isSelecting = false
    var isSelected = false
    var isDeleting = false
    var onToggleSelection: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        rowContent
        .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sessionHeaderMinHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .fill(isHovered ? AppTheme.Background.raisedColor : AppTheme.Background.surfaceColor)
                .overlay {
                    if isSelecting && isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                            .fill(AppTheme.Accent.link.opacity(AppTheme.Opacity.faint))
                    }
                }
                .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(
                    isSelecting && isSelected
                        ? AppTheme.Accent.link.opacity(AppTheme.Opacity.strong)
                        : (isHovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor),
                    lineWidth: isSelecting && isSelected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                )
        }
        .overlay(alignment: .trailing) {
            if !isSelecting && !isDeleting {
                trailingAction
            }
        }
        .contentShape(Rectangle())
        .disabled(isDeleting)
        .opacity(isDeleting ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.transition), value: isSelecting)
        .animation(reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.hover), value: isSelected)
    }

    @ViewBuilder
    private var rowContent: some View {
        if isSelecting && !isDeleting {
            Button { onToggleSelection?() } label: {
                HStack(spacing: AppTheme.Spacing.lg) {
                    LibrarySelectionIndicator(isSelected: isSelected)
                    sessionContent
                }
                .padding(AppTheme.Spacing.lgXl)
                .frame(maxWidth: .infinity, minHeight: AppTheme.Workbench.sessionHeaderMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.title)
            .accessibilityValue(L10n.string(isSelected ? "Selected" : "Not selected"))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .help(L10n.string(isSelected ? "Deselect session" : "Select session"))
        } else {
            standardRowContent
        }
    }

    private var standardRowContent: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Button(action: onOpen) {
                sessionContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isDeleting {
                SessionStatusInfoButton(status: session.status)
                Color.clear
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                    .help(L10n.string("Deleting session…"))
            }
        }
        .padding(AppTheme.Spacing.lgXl)
    }

    private var sessionContent: some View {
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
                        Text(L10n.string(key: session.sessionType.label))
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
            if isDeleting {
                Text(L10n.string("Deleting session…"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                SessionStatusBadge(status: session.status, iconOnlyAttention: true)
            }
        }
    }

    private var trailingAction: some View {
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
            .help(L10n.string("Delete session"))
            .disabled(!allowsDelete)
            .opacity(isHovered ? AppTheme.Opacity.opaque : AppTheme.Opacity.zero)
            .scaleEffect(isHovered ? 1 : 0.75)
            .allowsHitTesting(isHovered && allowsDelete)
        }
        .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
        .padding(.trailing, AppTheme.Spacing.lgXl)
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
        L10n.format(
            "%@ · %@",
            L10n.string(key: TaskPlacementCopy.storageTooltip(for: storage)),
            L10n.string(key: TaskPlacementCopy.computeTooltip(for: compute))
        )
    }

    var body: some View {
        HStack(spacing: showsLabel ? AppTheme.Spacing.xs : AppTheme.Spacing.md) {
            Image(systemName: storage == .local ? "internaldrive" : "icloud")
                .accessibilityLabel(L10n.string(key: TaskPlacementCopy.storageTooltip(for: storage)))
                .help(L10n.string(key: TaskPlacementCopy.storageTooltip(for: storage)))
            Image(systemName: compute == .local ? "laptopcomputer" : "cloud")
                .accessibilityLabel(L10n.string(key: TaskPlacementCopy.computeTooltip(for: compute)))
                .help(L10n.string(key: TaskPlacementCopy.computeTooltip(for: compute)))
            if showsLabel {
                Text(L10n.string(key: placementLabel))
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
