import AppKit
import SwiftUI

struct FontPickerField: View {
    let current: String?
    let onPreview: (String) -> Void
    let onChange: (String) -> Void
    let onCancel: () -> Void

    @State private var isPresented = false
    @State private var didPick = false

    var body: some View {
        Button {
            didPick = false
            isPresented = true
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(displayName)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .frame(maxWidth: AppTheme.EditorPanel.fontMenuWidth, alignment: .trailing)
            .editorValueField()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FontPickerPopover(
                current: current,
                onPreview: onPreview,
                onPick: { name in
                    didPick = true
                    onChange(name)
                    isPresented = false
                }
            )
            .frame(
                width: AppTheme.EditorPanel.fontPickerWidth,
                height: AppTheme.EditorPanel.fontPickerHeight
            )
        }
        .onChange(of: isPresented) { _, presented in
            if !presented, !didPick {
                onCancel()
            }
        }
    }

    private var displayName: String {
        guard let current else { return L10n.string("Mixed") }
        return NSFont(name: current, size: 12)?.familyName ?? current
    }
}

private struct FontPickerPopover: View {
    let current: String?
    let onPreview: (String) -> Void
    let onPick: (String) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var featuredMatches: [FontPickerEntry] {
        BundledFonts.families
            .filter { matches($0) }
            .map { FontPickerEntry(name: $0, previewable: true) }
    }

    private var systemMatches: [FontPickerEntry] {
        BundledFonts.systemFamiliesForPicker
            .filter { matches($0.name) }
            .map { FontPickerEntry(name: $0.name, previewable: $0.previewable) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                TextField(L10n.string("Filter fonts"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.smMd))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("Clear"))
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(AppTheme.Background.raisedColor)

            Divider()

            if featuredMatches.isEmpty, systemMatches.isEmpty {
                ContentUnavailableView(
                    L10n.string("No matching fonts"),
                    systemImage: "textformat",
                    description: Text(L10n.string("Try a different name or clear the filter."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !featuredMatches.isEmpty {
                            sectionHeader(L10n.string("Featured"))
                            ForEach(featuredMatches) { entry in
                                fontRow(entry)
                            }
                        }
                        if !featuredMatches.isEmpty, !systemMatches.isEmpty {
                            Divider()
                                .padding(.vertical, AppTheme.Spacing.xxs)
                        }
                        if !systemMatches.isEmpty {
                            sectionHeader(L10n.string("All fonts"))
                            ForEach(systemMatches) { entry in
                                fontRow(entry)
                            }
                        }
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                }
            }
        }
        .background(AppTheme.Background.surfaceColor)
        .onAppear {
            isSearchFocused = true
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fontRow(_ entry: FontPickerEntry) -> some View {
        let isSelected = entry.name == current
        return Button {
            onPick(entry.name)
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(entry.name)
                    .font(entry.previewable
                        ? .custom(entry.name, size: AppTheme.FontSize.md)
                        : .system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AppTheme.Spacing.zero)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.soft)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering else { return }
            onPreview(entry.name)
        }
    }

    private func matches(_ name: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(normalizedQuery)
    }
}

private struct FontPickerEntry: Identifiable {
    let name: String
    let previewable: Bool
    var id: String { name }
}
