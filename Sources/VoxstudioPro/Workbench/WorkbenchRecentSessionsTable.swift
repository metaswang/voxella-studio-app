import SwiftUI

/// Search + status filter row shared by the Import and Voiceover recent-session blocks.
struct WorkbenchRecentSessionFilterToolbar: View {
    @Binding var searchText: String
    @Binding var statusFilter: WorkbenchSessionStatusFilter
    var showsVoiceInput = false

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.mutedColor)
                TextField(L10n.string("Search"), text: $searchText)
                    .textFieldStyle(.plain)
                if showsVoiceInput {
                    InlineVoiceInputControl(text: $searchText, multiline: false)
                }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Clear search"))
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .frame(height: AppTheme.Workbench.recentSessionControlHeight)
            .frame(maxWidth: .infinity)
            .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            }

            Menu {
                ForEach(WorkbenchSessionStatusFilter.allCases) { filter in
                    Button {
                        statusFilter = filter
                    } label: {
                        if statusFilter == filter {
                            Label(L10n.string(key: filter.label), systemImage: "checkmark")
                        } else {
                            Text(L10n.string(key: filter.label))
                        }
                    }
                }
            } label: {
                Label(L10n.string("Filter"), systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .frame(height: AppTheme.Workbench.recentSessionControlHeight)
                    .background(
                        isFiltered ? AppTheme.Accent.link.opacity(AppTheme.Opacity.soft) : AppTheme.Background.raisedColor,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .strokeBorder(
                                isFiltered ? AppTheme.Accent.link.opacity(AppTheme.Opacity.moderate) : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    }
                    .foregroundStyle(isFiltered ? AppTheme.Accent.link : AppTheme.Text.secondaryColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // A borderless Menu otherwise grows to fill the row and squeezes the search field.
            .fixedSize()
            .help(
                isFiltered
                    ? L10n.format("Filter: %@", L10n.string(key: statusFilter.label))
                    : L10n.string("Filter sessions")
            )
        }
    }

    private var isFiltered: Bool { statusFilter != .all }
}

/// SESSION / UPDATED / TAGS table shared by the recent-session blocks.
struct WorkbenchRecentSessionsTable<Actions: View>: View {
    let sessions: [WorkbenchSession]
    let kindLabel: (WorkbenchSession) -> String
    let metadata: (WorkbenchSession) -> [String]
    let tag: (WorkbenchSession) -> String?
    let onOpen: (WorkbenchSession) -> Void
    @ViewBuilder let actions: (WorkbenchSession) -> Actions

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.zero) {
                Text("SESSION")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("UPDATED")
                    .frame(width: AppTheme.Workbench.recentSessionUpdatedColumnWidth, alignment: .leading)
                Text("TAGS")
                    .frame(width: AppTheme.Workbench.recentSessionTagColumnWidth, alignment: .leading)
                Color.clear.frame(width: AppTheme.Workbench.recentSessionMenuWidth)
            }
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.prominent))

            Divider()

            // Eager on purpose: this table sits in a parent's non-lazy VStack inside a
            // ScrollView, and a LazyVStack there spun forever re-placing each row's
            // AppKit-backed Menu (main thread hung, memory grew past 60 GB).
            VStack(spacing: AppTheme.Spacing.zero) {
                ForEach(sessions) { session in
                    row(session)
                    if session.id != sessions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    private func row(_ session: WorkbenchSession) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.zero) {
            Button {
                onOpen(session)
            } label: {
                HStack(alignment: .center, spacing: AppTheme.Spacing.zero) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                        WorkbenchSessionThumbnail(session: session)
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(session.title)
                                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.bold))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .lineLimit(1)
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Text(kindLabel(session))
                                    .foregroundStyle(AppTheme.Accent.link)
                                ForEach(Array(metadata(session).enumerated()), id: \.offset) { _, value in
                                    Text("·").opacity(AppTheme.Opacity.medium)
                                    Text(value)
                                }
                            }
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
                        Spacer(minLength: AppTheme.Spacing.zero)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(Self.relativeUpdated(session.modifiedAt))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                        .frame(width: AppTheme.Workbench.recentSessionUpdatedColumnWidth, alignment: .leading)

                    Text(tag(session) ?? "–")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .frame(width: AppTheme.Workbench.recentSessionTagColumnWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                actions(session)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Workbench.recentSessionMenuWidth, height: AppTheme.Workbench.recentSessionMenuWidth)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Keep the menu in its column; a borderless Menu otherwise takes the row's width.
            .frame(width: AppTheme.Workbench.recentSessionMenuWidth)
            .help(L10n.string("Session options"))
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.lg)
        .contextMenu {
            actions(session)
        }
    }

    /// A draft saved a moment ago can carry a timestamp slightly ahead of `Date()`;
    /// clamp it so the column never reads "in 0 seconds".
    private static func relativeUpdated(_ date: Date) -> String {
        let now = Date()
        return relativeFormatter.localizedString(for: min(date, now), relativeTo: now)
    }

    private static var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }
}
