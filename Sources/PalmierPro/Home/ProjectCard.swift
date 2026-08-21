import SwiftUI

struct ProjectCard: View {
    let entry: ProjectEntry
    let isSelecting: Bool
    let isSelected: Bool
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ProjectPackageThumbnail(
                url: entry.url,
                freshness: entry.lastOpenedDate,
                placeholderSize: AppTheme.FontSize.title2
            )
            .aspectRatio(5.0 / 4.0, contentMode: .fit)
            .overlay {
                if !entry.isAccessible {
                    Color.black.opacity(AppTheme.Opacity.high)

                    VStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: AppTheme.FontSize.title1))
                        Text("File missing")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(AppTheme.Opacity.high), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: AppTheme.ComponentSize.projectCardHeight / 2)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(entry.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                    .foregroundStyle(entry.isAccessible ? .white : AppTheme.Text.mutedColor)
                    .lineLimit(1)

                Text(ProjectRecency.string(for: entry.lastOpenedDate))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.white.opacity(AppTheme.Opacity.medium))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onSelect()
            } else if entry.isAccessible {
                onOpen(entry.url)
            }
        }
        .opacity(entry.isAccessible ? 1.0 : AppTheme.Opacity.strong)
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                    .padding(AppTheme.Spacing.smMd)
                    .allowsHitTesting(false)
            } else if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(AppTheme.Spacing.smMd)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? AppTheme.Accent.primary
                        : Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: isSelected ? AppTheme.BorderWidth.thick : AppTheme.BorderWidth.hairline
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            ProjectEntryContextActions(
                entry: entry,
                onOpen: onOpen,
                onRemove: onRemove,
                onDelete: onDelete
            )
        }
    }
}

struct ProjectPackageThumbnail: View {
    let url: URL
    var freshness: Date
    var maxPixelSize: Int = 640
    var placeholderSymbol: String = "film"
    var placeholderSize: CGFloat = AppTheme.FontSize.title1

    @State private var image: NSImage?

    var body: some View {
        AppTheme.Background.placeholderColor
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: placeholderSize, weight: AppTheme.FontWeight.light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .clipped()
            .task(id: taskID) { await load() }
    }

    private var taskID: String {
        "\(url.standardizedFileURL.path)|\(freshness.timeIntervalSinceReferenceDate)|\(maxPixelSize)"
    }

    private func load() async {
        image = nil
        let packageURL = url
        let pixelSize = maxPixelSize
        let cgImage = await Task.detached(priority: .utility) {
            let thumbURL = packageURL.appendingPathComponent(Project.thumbnailFilename, isDirectory: false)
            return ImageEncoder.thumbnail(url: thumbURL, maxPixelSize: pixelSize)
        }.value
        guard let cgImage, !Task.isCancelled else { return }
        image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

@MainActor
enum ProjectRecency {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func string(for date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ProjectEntryContextActions: View {
    let entry: ProjectEntry
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onDelete: () -> Void

    var body: some View {
        if entry.isAccessible {
            Button("Open") { onOpen(entry.url) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(
                    entry.url.path,
                    inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path
                )
            }
            Divider()
        }
        Button("Remove from Recents") { onRemove(entry.url) }
        Button("Delete Project", role: .destructive, action: onDelete)
    }
}
