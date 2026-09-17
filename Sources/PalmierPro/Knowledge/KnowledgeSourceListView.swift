import AppKit
import SwiftUI

struct KnowledgeSourceListView: View {
    @Bindable var controller: KnowledgeBaseController
    @Bindable private var workbench = WorkbenchStore.shared
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let transcriptSessionID = controller.transcriptSessionID,
               let session = controller.session(for: transcriptSessionID)
            {
                KnowledgeTranscriptView(session: session, target: controller.transcriptTarget) {
                    controller.closeTranscript()
                    listFocused = true
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(AppTheme.Border.subtleColor)
                    if workbench.isHydrating {
                        VStack(spacing: AppTheme.Spacing.md) {
                            ProgressView()
                            Text("Loading saved sessions…")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: AppTheme.Spacing.xs) {
                                allKnowledgeRow
                                ForEach(controller.rows) { row in
                                    sessionRow(row)
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.sm)
                        }
                    }
                }
                .focusable()
                .focused($listFocused)
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard !searchFocused else { return .ignored }
                    switch press.key {
                    case .upArrow:
                        return controller.moveListSelection(by: -1) ? .handled : .ignored
                    case .downArrow:
                        return controller.moveListSelection(by: 1) ? .handled : .ignored
                    case .rightArrow:
                        return controller.openSelectedTranscript() ? .handled : .ignored
                    default:
                        return .ignored
                    }
                }
            }
        }
        .background(AppTheme.Background.surfaceColor)
        .onAppear { listFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                Text(L10n.string("Knowledge"))
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.zero)
                Text(controller.scopeSubtitleForAll)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                TextField(L10n.string("Search knowledge"), text: $controller.listQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .focused($searchFocused)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.soft))
            )

            HStack(spacing: AppTheme.Spacing.xs) {
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

                Spacer(minLength: AppTheme.Spacing.zero)

                Toggle(isOn: Binding(
                    get: { controller.showAllSessions },
                    set: { controller.setShowAllSessions($0) }
                )) {
                    Text(L10n.string("Show all"))
                }
                .toggleStyle(.checkbox)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .help(L10n.string("Include sessions without a transcript. They are grayed out and cannot be used for QA until transcribed."))
            }
            .font(.system(size: AppTheme.FontSize.xxs))
        }
        .padding(AppTheme.Spacing.md)
    }

    private var allKnowledgeRow: some View {
        let selected = controller.selectedScope == .all
        return Button {
            controller.selectAll()
            listFocused = true
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
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
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .knowledgeSelectionChrome(isSelected: selected, emphasize: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: selected)
    }

    private func sessionRow(_ row: KnowledgeListRow) -> some View {
        let selected = controller.isSessionSelected(row.id)
        let qaAble = row.isQAAble
        return HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Button {
                    controller.handleSessionClick(row.id)
                    listFocused = true
                } label: {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                        row.sessionType.navGlyph.view(size: AppTheme.IconSize.sm)
                            .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                            .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(row.title)
                                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                                    .foregroundStyle(qaAble ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                    .layoutPriority(0)
                                Text(L10n.string(row.originBadge))
                                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                                    .padding(.horizontal, AppTheme.Spacing.sm)
                                    .padding(.vertical, AppTheme.Spacing.xxs)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                                    )
                                    .fixedSize(horizontal: true, vertical: false)
                                    .layoutPriority(1)
                            }
                            Text(row.metaLabel)
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(qaAble ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    controller.openAppSession(for: row.id)
                } label: {
                    Text(L10n.string("Open session"))
                }
                .buttonStyle(.link)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Accent.link)
                .padding(.leading, AppTheme.IconSize.lgXl + AppTheme.Spacing.smMd)
                .help(L10n.string("Open session"))
                .accessibilityLabel(L10n.string("Open session"))
            }

            Button {
                controller.openTranscript(for: row.id)
            } label: {
                Image(systemName: "text.quote")
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .disabled(controller.session(for: row.id)?.transcript == nil)
            .help(
                L10n.string(
                    controller.session(for: row.id)?.transcript == nil
                        ? "Transcript unavailable"
                        : "Open transcript"
                )
            )
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .opacity(qaAble ? 1 : AppTheme.Opacity.muted)
        .knowledgeSelectionChrome(isSelected: selected, emphasize: false)
        .contentShape(Rectangle())
        .onTapGesture {
            controller.handleSessionClick(row.id)
            listFocused = true
        }
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
            return emphasize ? AppTheme.Opacity.moderate : AppTheme.Opacity.muted
        }
        return isHovered ? AppTheme.Opacity.faint : AppTheme.Opacity.zero
    }

    private var ringOpacity: Double {
        isSelected ? (emphasize ? AppTheme.Opacity.medium : AppTheme.Opacity.moderate) : AppTheme.Opacity.zero
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
                            .frame(width: AppTheme.BorderWidth.thick)
                            .padding(.vertical, AppTheme.Spacing.sm)
                            .padding(.leading, AppTheme.Spacing.xs)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Accent.primary.opacity(ringOpacity), lineWidth: AppTheme.BorderWidth.thin)
                    .padding(AppTheme.BorderWidth.thin)
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
        if WorkbenchStore.shared.isHydrating {
            return "Loading saved sessions…"
        }
        let count = searchableSessionCount
        return "Ask across \(count) session\(count == 1 ? "" : "s")"
    }
}
