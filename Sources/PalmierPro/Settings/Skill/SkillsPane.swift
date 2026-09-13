import SwiftUI

struct SkillsPane: View {
    @Bindable private var store = SkillStore.shared
    @Bindable private var catalog = SkillCatalog.shared
    @State private var collection: SkillCollection = .installed
    @State private var query = ""
    @State private var presentedSkill: PresentedSkill?
    @State private var working: Set<String> = []

    private enum SkillCollection: String {
        case installed = "Installed"
        case community = "Community"
    }

    private struct PresentedSkill: Identifiable {
        let id: String
    }

    private var installedSkills: [Skill] {
        store.skills
            .filter { matches($0.name, $0.description, category: category(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var communityEntries: [SkillCatalogEntry] {
        catalog.entries
            .filter { matches($0.name, $0.description, category: $0.skillCategory) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var installedCategories: [SkillCategory] {
        sortedCategories(installedSkills.map(category(for:)))
    }

    private var communityCategories: [SkillCategory] {
        sortedCategories(communityEntries.map(\.skillCategory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            introduction
            controls
            ScrollView {
                skillList
            }
            .appScrollEdgeEffect(.top)
        }
        .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .onAppear {
            Task { await store.reloadInBackground() }
            Task { await catalog.refresh() }
        }
        .sheet(item: $presentedSkill) { item in
            SkillDetailSheet(skillID: item.id)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Install skills to give the in-app agent specialized workflows.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            if let url = URL(string: "https://github.com/voxstudio-me/voxstudio-skills") {
                Link("Browse Community Skills ↗", destination: url)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                    .pointerStyle(.link)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                SkillCollectionButton(
                    title: SkillCollection.installed.rawValue,
                    count: store.skills.count,
                    isSelected: collection == .installed,
                    action: { collection = .installed }
                )
                SkillCollectionButton(
                    title: SkillCollection.community.rawValue,
                    count: catalog.entries.count,
                    isSelected: collection == .community,
                    action: { collection = .community }
                )
            }

            Spacer(minLength: AppTheme.Spacing.md)

            searchField
                .frame(width: AppTheme.Settings.skillsSearchWidth)

            Button(action: createSkill) {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .padding(AppTheme.Spacing.xs)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New skill")
            .help("New skill")

            Menu {
                Button("Open Skills Folder", systemImage: "folder") { store.openFolder() }
                Divider()
                Button("Refresh Community Skills", systemImage: "arrow.clockwise") {
                    Task { await catalog.refresh() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .padding(AppTheme.Spacing.xs)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Skill actions")
            .help("Skill actions")
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .accessibilityHidden(true)

            TextField("Search skills", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .accessibilityLabel("Search skills")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.sm)
    }

    private var skillList: some View {
        LazyVStack(spacing: AppTheme.Spacing.sm) {
            switch collection {
            case .installed:
                installedList
            case .community:
                communityList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var installedList: some View {
        Group {
            if installedSkills.isEmpty, query.isEmpty {
                SkillEmptyState(
                    systemName: "book.closed",
                    title: "No Installed Skills",
                    message: "Create a skill or browse the Community collection.",
                    actionTitle: "New Skill",
                    action: createSkill
                )
            } else if installedSkills.isEmpty {
                noMatchesState
            } else {
                ForEach(installedCategories) { category in
                    SkillCategorySection(category: category, count: installedCount(in: category)) {
                        ForEach(installedSkills.filter { self.category(for: $0) == category }) { skill in
                            installedRow(skill, category: category)
                        }
                    }
                }
            }
        }
    }

    private var communityList: some View {
        Group {
            if catalog.isLoading, catalog.entries.isEmpty {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    ProgressView().controlSize(.small)
                    Text("Loading community skills…")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .frame(maxWidth: .infinity)
                .padding(AppTheme.Spacing.xlXxl)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading community skills")
            } else if communityEntries.isEmpty {
                if query.isEmpty, let error = catalog.lastError {
                    SkillEmptyState(
                        systemName: "exclamationmark.triangle",
                        title: "Community Skills Unavailable",
                        message: error,
                        actionTitle: "Try Again",
                        action: { Task { await catalog.refresh() } }
                    )
                } else if query.isEmpty {
                    SkillEmptyState(
                        systemName: "books.vertical",
                        title: "No Community Skills",
                        message: "Refresh to check for available skills.",
                        actionTitle: "Refresh",
                        action: { Task { await catalog.refresh() } }
                    )
                } else {
                    noMatchesState
                }
            } else {
                ForEach(communityCategories) { category in
                    SkillCategorySection(category: category, count: communityCount(in: category)) {
                        ForEach(communityEntries.filter { $0.skillCategory == category }) { entry in
                            communityRow(entry)
                        }
                    }
                }
            }
        }
    }

    private var noMatchesState: some View {
        SkillEmptyState(
            systemName: "magnifyingglass",
            title: "No Matching Skills",
            message: "Try another search.",
            actionTitle: "Clear Search",
            action: { query = "" }
        )
    }

    private func communityRow(_ entry: SkillCatalogEntry) -> some View {
        let skill = store.skills.first { $0.id == entry.id }
        let state = skill.flatMap { SkillCommunityState.resolve($0, store: store, catalog: catalog) }
        return SkillRow(
            systemImage: entry.skillCategory.systemImage,
            name: entry.name,
            description: entry.description,
            status: state?.label ?? (skill == nil ? "Available" : "Local"),
            statusColor: state?.color ?? AppTheme.Text.tertiaryColor,
            actionTitle: skill == nil ? "Install" : state == .update ? "Update" : "Open",
            working: working.contains(entry.id),
            summaryAction: skill.map { installedSkill in
                { present(installedSkill.id) }
            },
            action: {
                if let skill {
                    state == .update ? update(skill) : present(skill.id)
                } else {
                    install(entry)
                }
            }
        )
    }

    private func installedRow(_ skill: Skill, category: SkillCategory) -> some View {
        let state = SkillCommunityState.resolve(skill, store: store, catalog: catalog)
        return SkillRow(
            systemImage: category.systemImage,
            name: skill.name,
            description: skill.description,
            status: state?.label ?? "Local",
            statusColor: state?.color ?? AppTheme.Text.tertiaryColor,
            actionTitle: state == .update ? "Update" : "Open",
            working: working.contains(skill.id),
            summaryAction: { present(skill.id) },
            action: { state == .update ? update(skill) : present(skill.id) }
        )
    }

    private func matches(_ name: String, _ description: String, category: SkillCategory? = nil) -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(search)
            || description.localizedCaseInsensitiveContains(search)
            || category?.title.localizedCaseInsensitiveContains(search) == true
    }

    private func category(for skill: Skill) -> SkillCategory {
        catalog.entry(id: skill.id)?.skillCategory ?? .local
    }

    private func sortedCategories(_ categories: [SkillCategory]) -> [SkillCategory] {
        Set(categories).sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func installedCount(in category: SkillCategory) -> Int {
        installedSkills.count { self.category(for: $0) == category }
    }

    private func communityCount(in category: SkillCategory) -> Int {
        communityEntries.count { $0.skillCategory == category }
    }

    private func createSkill() {
        guard let id = store.newSkill() else { return }
        collection = .installed
        query = ""
        present(id)
    }

    private func install(_ entry: SkillCatalogEntry) {
        working.insert(entry.id)
        Task {
            let installed = await store.install(entry)
            working.remove(entry.id)
            if installed {
                collection = .installed
                query = ""
                present(entry.id)
            }
        }
    }

    private func update(_ skill: Skill) {
        guard let entry = catalog.entry(id: skill.id) else { return }
        working.insert(skill.id)
        Task {
            _ = await store.install(entry)
            working.remove(skill.id)
        }
    }

    private func present(_ id: String) {
        presentedSkill = PresentedSkill(id: id)
    }
}
