import SwiftUI

struct LocalFeaturePreparationRow: View {
    let feature: LocalPreparationFeature
    var allowsRemoval = false
    @State private var showsRemovalConfirmation = false
    @Bindable private var manager = LocalModelManager.shared

    private var status: LocalPreparationStatus { manager.preparationStatus(for: feature) }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: feature.icon)
                    .font(.system(size: AppTheme.FontSize.xl))
                    .foregroundStyle(AppTheme.Accent.primary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string(feature.title))
                        .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                    Text(L10n.string(feature.detail))
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                Spacer()
                if status.isReady {
                    Label(L10n.string("Ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Status.successColor)
                } else if status.isBusy {
                    Button(L10n.string("Cancel download")) {
                        manager.cancelFeature(feature)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(L10n.string(status.hasFailure ? "Retry" : "Download")) {
                        manager.prepareFeatures([feature])
                    }
                    .buttonStyle(.bordered)
                }
            }
            if allowsRemoval, !status.isBusy, !manager.removableResources(for: feature).isEmpty {
                Button(L10n.string("Remove download…"), role: .destructive) {
                    showsRemovalConfirmation = true
                }
                .buttonStyle(.borderless)
            }
            if status.isBusy {
                ProgressView(value: status.progress)
                    .accessibilityLabel(L10n.string(feature.title))
                Text(L10n.display(status.userFacingMessage))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if status.hasFailure {
                Text(L10n.display(status.currentMessage ?? "The resource download failed. Try again."))
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else if !status.isReady {
                Text(L10n.string("Estimated download") + ": " + LocalModelInstallPlan.formatBytes(status.remainingBytes))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            resourceDetails
        }
        .alert(L10n.string("Remove downloaded resources?"), isPresented: $showsRemovalConfirmation) {
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(L10n.string("Remove"), role: .destructive) { manager.removeFeatureResources(feature) }
        } message: {
            Text(L10n.string(feature == .search
                ? "Removing this download disables meaning and visual search until you download it again."
                : "Shared speech resources stay available. Using this feature again may require another download."))
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    /// License and source of each resource; recorded automatically, never asked.
    private var resourceDetails: some View {
        DisclosureGroup(L10n.string("Resource details")) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(feature.requiredIDs(asrModelID: manager.activeASRModelID), id: \.self) { id in
                    if let model = LocalModelManager.catalog.first(where: { $0.id == id }) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("\(model.title) · \(model.sizeLabel)")
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text(L10n.string("License") + ":")
                                if let url = model.licenseURL {
                                    Link(model.license, destination: url)
                                } else {
                                    Text(model.license)
                                }
                            }
                            Text(L10n.string("Source") + ": \(model.repository) @ \(String(model.revision.prefix(8)))")
                                .textSelection(.enabled)
                        }
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
            }
            .padding(.top, AppTheme.Spacing.xs)
        }
        .font(.system(size: AppTheme.FontSize.sm))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
    }
}
