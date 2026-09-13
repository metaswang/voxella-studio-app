import SwiftUI

struct FirstRunRootView: View {
    @Bindable private var onboarding = OnboardingState.shared
    @Bindable private var appState = AppState.shared

    var body: some View {
        Group {
            if !onboarding.isComplete && appState.editorPresentation != .active {
                OnboardingView(state: onboarding)
            } else {
                HomeView()
            }
        }
    }
}

struct OnboardingView: View {
    @Bindable var state: OnboardingState
    @Bindable private var manager = LocalModelManager.shared

    private var ids: [LocalModelID] {
        LocalPreparationFeature.requiredIDs(for: state.selectedFeatures, asrModelID: manager.activeASRModelID)
    }

    private var status: LocalPreparationStatus { manager.preparationStatus(for: ids) }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            FeatureShowcase()
                .frame(width: AppTheme.Onboarding.showcaseWidth)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "waveform.path")
                        .foregroundStyle(AppTheme.Onboarding.ink)
                    Text("VoxStudio")
                        .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
                    Spacer()
                    ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                        Capsule()
                            .fill(step == state.step ? AppTheme.Onboarding.ink : AppTheme.Border.subtleColor)
                            .frame(width: AppTheme.IconSize.sm, height: AppTheme.Spacing.xs)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("VoxStudio. " + L10n.string(stepTitle(state.step)))
                Group {
                    if state.step == .features {
                        stepContent
                    } else {
                        ScrollView { stepContent }
                            .scrollIndicators(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(AppTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.Onboarding.paper)
        }
        .frame(width: AppTheme.Onboarding.panelWidth, height: AppTheme.Onboarding.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Onboarding.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Onboarding.panelRadius)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        }
        .compositingGroup()
        .shadow(AppTheme.Shadow.lg)
        .frame(minWidth: AppTheme.Window.homeMin.width, minHeight: AppTheme.Window.homeMin.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            if state.step == .features { Spacer().frame(height: AppTheme.Spacing.xxl) }
            Text(L10n.string(title))
                .font(.system(size: state.step == .features ? AppTheme.FontSize.display : AppTheme.FontSize.title2, weight: AppTheme.FontWeight.semibold))
                .tracking(-AppTheme.BorderWidth.hairline)
                .fixedSize(horizontal: false, vertical: true)
            switch state.step {
            case .features: introduction
            case .selection: selection
            case .preparation: preparation
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Text(L10n.string("Turn recordings into words, scripts into voices, and footage into a finished story."))
                .font(.system(size: AppTheme.FontSize.lg))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                introLine("captions.bubble", "Transcribe and translate")
                introLine("waveform", "Create a voiceover")
                introLine("timeline.selection", "Find, arrange, and edit")
            }
            Text(L10n.string("Start with what you need. Add more whenever you're ready."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func introLine(_ icon: String, _ title: String) -> some View {
        Label {
            Text(L10n.string(title))
                .foregroundStyle(AppTheme.Text.primaryColor)
        } icon: {
            Image(systemName: icon).foregroundStyle(AppTheme.Onboarding.ink)
        }
        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
    }

    private var title: String {
        switch state.step {
        case .features: "From first take\nto final cut."
        case .selection: "Make it yours."
        case .preparation: status.isReady ? "You're ready to begin" : "Preparing your local features"
        }
    }

    private func stepTitle(_ step: OnboardingState.Step) -> String {
        switch step {
        case .features: "1 · Discover"
        case .selection: "2 · Choose"
        case .preparation: "3 · Get ready"
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text(L10n.string("Choose the features you want to run on this Mac. Download them once to use them locally."))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            ForEach(LocalPreparationFeature.allCases) { feature in
                Toggle(isOn: Binding(
                    get: { state.selectedFeatures.contains(feature) },
                    set: { selected in
                        if selected { state.selectedFeatures.insert(feature) }
                        else { state.selectedFeatures.remove(feature) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Label(L10n.string(feature.title), systemImage: feature.icon)
                            .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                        Text(L10n.string(feature.detail))
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(AppTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            }
            downloadNotice
            Label(LocalModelInstallPlan.formatBytes(status.remainingBytes), systemImage: "arrow.down.circle")
                .accessibilityLabel(L10n.string("Estimated download") + " " + LocalModelInstallPlan.formatBytes(status.remainingBytes))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
            Text(L10n.string("Cloud processing is available separately and may require an account and credits."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if state.selectedFeatures.isEmpty {
                Label(L10n.string("No downloads selected"), systemImage: "checkmark.circle")
            }
            ForEach(LocalPreparationFeature.allCases.filter { state.selectedFeatures.contains($0) }) { feature in
                LocalFeaturePreparationRow(feature: feature)
            }
            downloadNotice
            if status.isBusy {
                Text(L10n.string("You can continue while downloads finish. Approved downloads resume when you reopen the app."))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }

    private var downloadNotice: some View {
        Text(L10n.string("You can add other local features later. Before their first task starts, we'll show the required download and ask you to continue."))
            .font(.system(size: AppTheme.FontSize.md))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            if state.step == .selection {
                Button(L10n.string("Back")) { state.showFeatures() }
            }
            Spacer()
            switch state.step {
            case .features:
                Button(L10n.string("Continue")) { state.showSelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .selection:
                Button(L10n.string(state.selectedFeatures.isEmpty ? "Continue without downloads" : "Download and continue")) {
                    state.prepare(startDownloads: manager.prepareFeatures)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .preparation:
                Button(L10n.string(status.isReady ? "Continue" : "Continue to Dashboard")) {
                    WorkbenchStore.shared.route = .dashboard
                    state.complete()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .tint(AppTheme.Onboarding.ink)
        .padding(.top, AppTheme.Spacing.sm)
    }
}
