import SwiftUI

struct SessionSummaryTemplateSheet: View {
    let currentTemplateID: String?
    let onCancel: () -> Void
    let onApply: (SummaryTemplateDefinition) -> Void

    @State private var tree: SummaryTemplateTree?
    @State private var isTreeLoading = true
    @State private var loadError: String?
    @State private var expandedCategories: Set<String> = []
    @State private var activeTemplateID: String?
    @State private var isContentLoading = false
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var draftUserEdition = ""
    @State private var loadedName = ""
    @State private var loadedDescription = ""
    @State private var loadedUserEdition = ""
    @State private var aiAssistOpen = false
    @State private var aiInstruction = ""
    @State private var aiCandidate = ""
    @State private var isAIAssistLoading = false
    @State private var isApplying = false
    @State private var applyError: String?
    @FocusState private var isRequirementFocused: Bool

    private var locale: String {
        SummaryTemplateLocale.resolve(AppLocalization.shared.activeIdentifier)
    }

    private var canApply: Bool {
        activeTemplateID != nil
            && !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftUserEdition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isTreeLoading
            && !isContentLoading
            && !isApplying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: AppTheme.Workbench.summaryTemplateSidebarWidth * 0.75,
                           idealWidth: AppTheme.Workbench.summaryTemplateSidebarWidth,
                           maxWidth: AppTheme.Workbench.summaryTemplateSidebarWidth * 1.35)
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(
            width: AppTheme.Workbench.summaryTemplateSheetWidth,
            height: AppTheme.Workbench.summaryTemplateSheetHeight
        )
        .background(AppTheme.Background.surfaceColor)
        .task { await loadTree() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("My Template")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
            Text("Choose a template and edit the requirement before applying it to this summary.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private var sidebar: some View {
        ScrollView {
            if isTreeLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.lg)
            } else if let loadError {
                Text(loadError)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .padding(AppTheme.Spacing.lg)
            } else if let tree, !tree.categories.isEmpty {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    ForEach(tree.categories) { category in
                        categorySection(category)
                    }
                }
                .padding(AppTheme.Spacing.md)
            } else {
                Text("No templates are available yet.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(AppTheme.Spacing.lg)
            }
        }
        .background(AppTheme.Background.raisedColor)
    }

    @ViewBuilder
    private func categorySection(_ category: SummaryTemplateTree.Category) -> some View {
        let isExpanded = expandedCategories.contains(category.code)
        Button {
            if isExpanded {
                expandedCategories.remove(category.code)
            } else {
                expandedCategories.insert(category.code)
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(category.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.zero)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isExpanded {
            ForEach(category.children) { subcategory in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(subcategory.name)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.leading, AppTheme.Spacing.xl)
                    ForEach(subcategory.templates) { template in
                        templateRow(template)
                    }
                }
            }
        }
    }

    private func templateRow(_ template: SummaryTemplateDefinition) -> some View {
        let isActive = activeTemplateID?.caseInsensitiveCompare(template.id) == .orderedSame
        return Button {
            Task { await selectTemplate(template) }
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text((template.emojiIcon?.isEmpty == false ? template.emojiIcon : nil) ?? "📄")
                    .font(.system(size: AppTheme.FontSize.mdLg))
                Text(template.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Spacer(minLength: AppTheme.Spacing.zero)
                if template.isPrivate {
                    Text("Private")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Accent.link)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(AppTheme.Accent.link.opacity(AppTheme.Opacity.soft), in: Capsule())
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive
                    ? AppTheme.Accent.link.opacity(AppTheme.Opacity.soft)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, AppTheme.Spacing.xl)
    }

    private var editor: some View {
        Group {
            if isContentLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if activeTemplateID != nil {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Name")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        TextField("Template name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("Summary requirement")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draftUserEdition)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .scrollContentBackground(.hidden)
                            .padding(AppTheme.Spacing.sm)
                            .focused($isRequirementFocused)
                    }
                    .frame(minHeight: AppTheme.Workbench.summaryTemplateEditorMinHeight, maxHeight: .infinity)
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    }

                    HStack {
                        Button {
                            aiAssistOpen.toggle()
                        } label: {
                            Label("AI Edit", systemImage: "sparkles")
                        }
                        .disabled(isAIAssistLoading || isApplying)
                        Spacer()
                    }

                    if aiAssistOpen {
                        aiAssistPanel
                    }

                    if let applyError {
                        Text(applyError)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Status.errorColor)
                    }
                }
                .padding(AppTheme.Spacing.lgXl)
            } else {
                Text("Select a template first")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var aiAssistPanel: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Let AI help refine your requirement")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Describe what you want AI to edit", text: $aiInstruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button {
                    Task { await runAIAssist() }
                } label: {
                    if isAIAssistLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Apply AI Edit")
                    }
                }
                .disabled(aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAIAssistLoading)
            }
            if !aiCandidate.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Preview")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    ScrollView {
                        Text(aiCandidate)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                    HStack {
                        Spacer()
                        Button("Cancel") { aiCandidate = "" }
                        Button("Apply") { applyAICandidate() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(AppTheme.Spacing.md)
                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.baseColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
            Button("Apply") {
                Task { await applyTemplate() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private func loadTree() async {
        isTreeLoading = true
        loadError = nil
        do {
            let loaded = try await SummaryTemplateCatalog.shared.fetchTree(
                locale: locale,
                forceRefresh: true
            )
            tree = loaded
            if expandedCategories.isEmpty, let first = loaded.categories.first {
                expandedCategories.insert(first.code)
            }
            await selectInitialTemplate(in: loaded)
        } catch {
            loadError = error.localizedDescription
        }
        isTreeLoading = false
    }

    private func selectInitialTemplate(in tree: SummaryTemplateTree) async {
        var initialID = currentTemplateID
        if let selectedID = initialID {
            let item = tree.template(id: selectedID)
            if item == nil || item?.isPrivate != true,
               let shadow = tree.privateCopy(ofPublicTemplateID: selectedID) {
                initialID = shadow.id
            }
        }
        if initialID == nil || tree.template(id: initialID) == nil {
            initialID = tree.templates.first?.id
        }
        guard let initialID, let item = tree.template(id: initialID) else { return }
        expandCategory(containing: initialID, in: tree)
        await selectTemplate(item)
    }

    private func expandCategory(containing templateID: String, in tree: SummaryTemplateTree) {
        for category in tree.categories where category.children.contains(where: { subcategory in
            subcategory.templates.contains { $0.id.caseInsensitiveCompare(templateID) == .orderedSame }
        }) {
            expandedCategories.insert(category.code)
        }
    }

    private func selectTemplate(_ item: SummaryTemplateDefinition) async {
        activeTemplateID = item.id
        applyError = nil
        aiAssistOpen = false
        aiInstruction = ""
        aiCandidate = ""
        applyDraft(
            name: item.name,
            description: item.description,
            userEdition: item.userEdition
        )
        isContentLoading = true
        defer { isContentLoading = false }
        do {
            let full = try await SummaryTemplateCatalog.shared.loadTemplate(id: item.id, locale: locale)
            applyDraft(name: full.name, description: full.description, userEdition: full.userEdition)
        } catch {
            if item.userEdition.isEmpty {
                applyError = error.localizedDescription
            }
        }
    }

    private func applyDraft(name: String, description: String, userEdition: String) {
        draftName = name
        draftDescription = description
        draftUserEdition = userEdition
        loadedName = name
        loadedDescription = description
        loadedUserEdition = userEdition
    }

    private func runAIAssist() async {
        guard let activeTemplateID else { return }
        isAIAssistLoading = true
        applyError = nil
        defer { isAIAssistLoading = false }
        do {
            let candidate = try await SummaryTemplateCatalog.shared.assistEdit(
                templateID: activeTemplateID,
                instruction: aiInstruction,
                currentUserEdition: draftUserEdition
            )
            if candidate.isEmpty {
                applyError = "AI did not return an updated requirement."
            } else {
                aiCandidate = candidate
            }
        } catch {
            applyError = error.localizedDescription
        }
    }

    private func applyAICandidate() {
        guard !aiCandidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftUserEdition = aiCandidate
        aiCandidate = ""
        aiInstruction = ""
        aiAssistOpen = false
    }

    private func applyTemplate() async {
        guard let activeTemplateID, canApply else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let edition = draftUserEdition.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = activeTemplateID.caseInsensitiveCompare(currentTemplateID ?? "") == .orderedSame
            && name == loadedName.trimmingCharacters(in: .whitespacesAndNewlines)
            && description == loadedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            && edition == loadedUserEdition.trimmingCharacters(in: .whitespacesAndNewlines)
        if unchanged,
           currentTemplateID != nil,
           let selected = tree?.template(id: activeTemplateID) {
            onApply(
                SummaryTemplateDefinition(
                    id: activeTemplateID,
                    name: name,
                    description: description,
                    userEdition: edition,
                    isFallback: selected.isFallback,
                    categoryCode: selected.categoryCode,
                    scope: selected.scope,
                    sourceTemplateID: selected.sourceTemplateID,
                    emojiIcon: selected.emojiIcon
                )
            )
            return
        }

        isApplying = true
        applyError = nil
        defer { isApplying = false }
        do {
            let resolved = try await SummaryTemplateCatalog.shared.persistDraft(
                templateID: activeTemplateID,
                name: name,
                description: description,
                userEdition: edition
            )
            onApply(resolved)
        } catch {
            applyError = error.localizedDescription
        }
    }
}
