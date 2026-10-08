import SwiftUI

/// Shows the project a session belongs to and lets the user move it.
/// Sessions outside every project get a dashed "Add to project" affordance,
/// so the header always offers one place to file a session.
struct SessionProjectChip: View {
    let session: WorkbenchSession
    @Bindable private var projects = WorkbenchProjectsStore.shared
    @State private var isPresented = false
    @State private var isHovering = false

    private var currentProject: WorkbenchSessionProject? {
        projects.project(for: session)
    }

    var body: some View {
        let isAssigned = currentProject != nil
        Button { isPresented.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: isAssigned ? "folder" : "folder.badge.plus")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                Text(currentProject?.name ?? L10n.string("Add to project"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: AppTheme.Workbench.sessionProjectNameMaxWidth, alignment: .leading)
                if isAssigned {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(isAssigned ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(chipFill(isAssigned: isAssigned), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isAssigned ? AppTheme.Border.subtleColor : AppTheme.Border.primaryColor,
                    style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: isAssigned ? [] : [AppTheme.zoomed(3), AppTheme.zoomed(2)])
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SessionProjectPicker(session: session) { isPresented = false }
                .appZoomEnvironment(presentationBoundary: true)
        }
        .help(currentProject.map { L10n.format("Project: %@", $0.name) } ?? L10n.string("Add to project"))
        .accessibilityLabel(currentProject.map { L10n.format("Project: %@", $0.name) } ?? L10n.string("Add to project"))
        .accessibilityHint(L10n.string("Change project"))
        .accessibilityIdentifier("session.project")
    }

    private func chipFill(isAssigned: Bool) -> Color {
        if isPresented || isHovering {
            return AppTheme.Background.prominentColor
        }
        return isAssigned ? AppTheme.Background.raisedColor : .clear
    }
}

/// Popover content for choosing, removing, or creating a project for one session.
/// Every choice applies immediately and closes the popover; creation is inline so
/// the user never leaves the session to file it.
private struct SessionProjectPicker: View {
    let session: WorkbenchSession
    let dismiss: () -> Void
    @Bindable private var projects = WorkbenchProjectsStore.shared
    @State private var isCreating = false
    @State private var newProjectName = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var currentProjectID: UUID? {
        projects.project(for: session)?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(L10n.string("Project"))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.top, AppTheme.Spacing.xs)
                .padding(.bottom, AppTheme.Spacing.xxs)

            if projects.projects.isEmpty {
                Text(L10n.string("No projects yet"))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        ForEach(projects.projects) { project in
                            SessionProjectOptionRow(
                                title: project.name,
                                icon: "folder",
                                isSelected: project.id == currentProjectID
                            ) {
                                choose(project.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: AppTheme.Workbench.sessionProjectListMaxHeight)
            }

            if currentProjectID != nil {
                Divider().padding(.vertical, AppTheme.Spacing.xxs)
                SessionProjectOptionRow(
                    title: L10n.string("Remove from project"),
                    icon: "folder.badge.minus",
                    isSelected: false
                ) {
                    choose(nil)
                }
            }

            Divider().padding(.vertical, AppTheme.Spacing.xxs)
            if isCreating {
                newProjectField
            } else {
                SessionProjectOptionRow(
                    title: L10n.string("New project"),
                    icon: "plus",
                    isSelected: false
                ) {
                    errorMessage = nil
                    isCreating = true
                }
            }

            if let errorMessage {
                Text(L10n.display(errorMessage))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.xs)
        .frame(width: AppTheme.Workbench.sessionProjectPopoverWidth)
    }

    private var newProjectField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            TextField(L10n.string("Project name"), text: $newProjectName)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .focused($isNameFocused)
                .onSubmit(createProject)
                .onExitCommand {
                    newProjectName = ""
                    isCreating = false
                }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(minHeight: AppTheme.Workbench.homeRowHeight)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .onAppear { isNameFocused = true }
    }

    private func choose(_ projectID: UUID?) {
        do {
            try projects.move(session, to: projectID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try projects.create(name: name, session: session)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SessionProjectOptionRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: icon)
                    .frame(width: AppTheme.IconSize.smMd)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AppTheme.Spacing.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(minHeight: AppTheme.Workbench.homeRowHeight)
            .background(
                isHovering ? AppTheme.Background.prominentColor : .clear,
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
