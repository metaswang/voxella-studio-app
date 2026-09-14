import AppKit
import SwiftUI

struct KnowledgeSourceListView: View {
    @Bindable var controller: KnowledgeBaseController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.xs) {
                    allKnowledgeRow
                    ForEach(controller.rows) { row in
                        sessionRow(row)
                    }
                }
                .padding(AppTheme.Spacing.md)
            }
        }
        .background(AppTheme.Background.surfaceColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Knowledge"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                TextField(L10n.string("Search knowledge"), text: $controller.listQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.smMd))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.soft))
            )

            HStack(spacing: AppTheme.Spacing.sm) {
                Picker(L10n.string("Type"), selection: $controller.typeFilter) {
                    ForEach(KnowledgeSourceType.allCases.filter { $0 != .other }) { type in
                        Text(L10n.string(type.label)).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Picker(L10n.string("Status"), selection: $controller.indexFilter) {
                    ForEach(KnowledgeIndexFilter.allCases) { filter in
                        Text(L10n.string(filter.label)).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help(L10n.string("Index status is approximate (has transcript). Real SessionIndex flags land in P1."))

                Picker(L10n.string("Origin"), selection: Binding(
                    get: { controller.originFilter },
                    set: { controller.setOriginFilter($0) }
                )) {
                    ForEach(KnowledgeOriginFilter.allCases) { filter in
                        Text(L10n.string(filter.label)).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!AccountService.shared.isSignedIn && controller.originFilter != .local && controller.originFilter != .all)
                .help(L10n.string("Cloud sessions are hidden while signed out."))
            }
            .font(.system(size: AppTheme.FontSize.xs))

            Toggle(isOn: Binding(
                get: { controller.showAllSessions },
                set: { controller.setShowAllSessions($0) }
            )) {
                Text(L10n.string("Show all"))
            }
            .toggleStyle(.checkbox)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .help(L10n.string("Include sessions without a transcript. They are grayed out and cannot be used for QA until transcribed."))

            Text(L10n.string("Indexed ≈ has transcript (approx.)"))
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(AppTheme.Spacing.md)
    }

    private var allKnowledgeRow: some View {
        let selected = controller.selectedScope == .all
        return Button {
            controller.selectAll()
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("All knowledge"))
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(controller.scopeSubtitleForAll)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.md)
            .knowledgeSelectionChrome(isSelected: selected, emphasize: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selected)
    }

    private func sessionRow(_ row: KnowledgeListRow) -> some View {
        let selected = controller.isSessionSelected(row.id)
        let qaAble = row.isQAAble
        return Button {
            controller.handleSessionClick(row.id)
        } label: {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                row.sessionType.navGlyph.view(size: 18)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(row.title)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                            .foregroundStyle(qaAble ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(0)
                        Text(L10n.string(row.originBadge))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    Text(row.metaLabel)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                    Text(L10n.string(row.statusLabel))
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                        .foregroundStyle(qaAble ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.md)
            .opacity(qaAble ? 1 : 0.55)
            .knowledgeSelectionChrome(isSelected: selected, emphasize: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string(row.indexStatusHelp))
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selected)
    }
}

// MARK: - Selection chrome (no system List gray bar)

private struct KnowledgeSelectionChrome: ViewModifier {
    var isSelected: Bool
    var emphasize: Bool
    @State private var isHovered = false

    private var fillOpacity: Double {
        if isSelected {
            return emphasize ? 0.18 : 0.14
        }
        return isHovered ? AppTheme.Opacity.faint : 0
    }

    private var ringOpacity: Double {
        isSelected ? (emphasize ? 0.40 : 0.32) : 0
    }

    func body(content: Content) -> some View {
        content
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    AppTheme.Accent.primary.opacity(fillOpacity),
                                    AppTheme.Accent.primary.opacity(fillOpacity * 0.55),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(AppTheme.Accent.primary)
                            .frame(width: 3)
                            .padding(.vertical, 8)
                            .padding(.leading, 3)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Accent.primary.opacity(ringOpacity), lineWidth: 1)
                    .padding(1)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}

private extension View {
    func knowledgeSelectionChrome(isSelected: Bool, emphasize: Bool) -> some View {
        modifier(KnowledgeSelectionChrome(isSelected: isSelected, emphasize: emphasize))
    }
}

extension KnowledgeBaseController {
    var scopeSubtitleForAll: String {
        let count = searchableSessionCount
        return "Ask across \(count) session\(count == 1 ? "" : "s")"
    }
}
