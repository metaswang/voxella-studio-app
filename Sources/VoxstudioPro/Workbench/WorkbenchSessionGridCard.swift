import SwiftUI

struct SessionGridCard: View {
    let session: WorkbenchSession
    let isSelecting: Bool
    let isSelected: Bool
    let isDeleting: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onToggleSelection: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: activate) {
                poster
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.title)
            .accessibilityValue(isSelecting ? L10n.string(isSelected ? "Selected" : "Not selected") : "")
            .accessibilityAddTraits(isSelecting && isSelected ? [.isSelected] : [])
            .overlay(alignment: .topTrailing) {
                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(AppTheme.Spacing.smMd)
                        .background(AppTheme.Background.surfaceColor, in: Circle())
                        .padding(AppTheme.Spacing.smMd)
                } else if isHovered && !isSelecting {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                            .foregroundStyle(AppTheme.Status.errorColor)
                            .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                            .background(AppTheme.Background.raisedColor, in: Circle())
                            .overlay {
                                Circle().strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Delete session"))
                    .accessibilityLabel(L10n.string("Delete session"))
                    .padding(AppTheme.Spacing.smMd)
                }
            }
            .padding(AppTheme.Spacing.sm)

            details
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.top, AppTheme.Spacing.sm)
                .padding(.bottom, AppTheme.Spacing.lg)
        }
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .fill(isHovered ? AppTheme.Background.raisedColor : AppTheme.Background.surfaceColor)
                .overlay {
                    if isSelecting && isSelected {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                            .fill(AppTheme.Accent.link.opacity(AppTheme.Opacity.faint))
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                .strokeBorder(
                    isSelecting && isSelected
                        ? AppTheme.Accent.link
                        : (isHovered ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor),
                    lineWidth: isSelecting && isSelected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                )
        }
        .shadow(isHovered ? AppTheme.Shadow.md : AppTheme.Shadow.sm)
        .disabled(isDeleting)
        .opacity(isDeleting ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: AppTheme.Anim.hover), value: isSelected)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Button(action: activate) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(session.title)
                        .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(2, reservesSpace: true)
                    HStack(spacing: AppTheme.Spacing.smMd) {
                        Text(L10n.string(key: session.sessionType.label))
                            .lineLimit(1)
                        if let duration = session.duration {
                            Text(formatTime(duration))
                                .fixedSize()
                        }
                    }
                    Text(session.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .lineLimit(1)
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isSelecting ? L10n.string(isSelected ? "Selected" : "Not selected") : "")
            .accessibilityAddTraits(isSelecting && isSelected ? [.isSelected] : [])

            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)

            HStack(spacing: AppTheme.Spacing.smMd) {
                SessionPlacementIndicators(storage: session.storage, compute: session.compute, showsLabel: true)
                Spacer(minLength: 0)
                if isDeleting {
                    Text(L10n.string("Deleting session…"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                } else {
                    SessionStatusBadge(status: session.status, iconOnlyAttention: true)
                    if !isSelecting {
                        SessionStatusInfoButton(status: session.status)
                    }
                }
            }
            .frame(minHeight: AppTheme.IconSize.mdLg)
        }
    }

    private var poster: some View {
        GeometryReader { proxy in
            WorkbenchSessionThumbnail(
                session: session,
                size: proxy.size,
                showsTypeBadge: true,
                placeholderSize: AppTheme.IconSize.xl
            )
                .overlay {
                    if isHovered && !isSelecting && !isDeleting {
                        AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.VideoEditorHome.hoverOpenOverlay)
                        Text(L10n.string("Open"))
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                            .foregroundStyle(AppTheme.MediaOverlay.primaryColor)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.vertical, AppTheme.Spacing.smMd)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay(alignment: .bottomTrailing) {
                    if isSelecting && !isDeleting {
                        LibrarySelectionIndicator(isSelected: isSelected)
                            .background(AppTheme.Background.surfaceColor, in: Circle())
                            .padding(AppTheme.Spacing.smMd)
                    }
                }
        }
        .aspectRatio(AppTheme.VideoEditorHome.posterAspect, contentMode: .fit)
    }

    private func activate() {
        guard !isDeleting else { return }
        if isSelecting {
            onToggleSelection()
        } else {
            onOpen()
        }
    }
}
