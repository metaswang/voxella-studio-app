import AVFoundation
import SwiftUI

struct ProcessingOptionsSheet: View {
    enum Mode: Equatable {
        case upload
        case retranscribe
    }

    let mediaURLs: [URL]
    var mode: Mode = .upload
    var initialOptions: LocalProcessingOptions?
    var initialPlacement: TranscriptionPlacement = .localDefault
    var allowsCloudStorage = true
    var onPrepareCloud: ((TranscriptionPlacement) async -> CloudAccessPreparation)?
    let onCancel: () -> Void
    let onContinue: (TranscriptionSubmission) -> Void

    @State private var languageCode: String? = WorkbenchTranscriptionLanguage.automatic.languageCode
    @State private var sessionTitle = ""
    @State private var showAdvanced = false
    @State private var speakerCount: SpeakerCountOption = .auto
    @State private var enableSubtitleSegmentation = false
    @State private var enableClip = false
    @State private var clipRange: ClosedRange<Double> = 0...1
    @State private var hasExplicitClipRange = false
    @State private var enableTranslation = false
    @State private var targetLanguageCode = ""
    @State private var didApplyInitialOptions = false
    @State private var storageDestination: TaskStorageDestination = .local
    @State private var computeDestination: TaskComputeDestination = .local
    @State private var isPreparingCloud = false
    @State private var cloudAccessError: String?
    @State private var mediaDurationSeconds: Double?
    @State private var cloudQuota: CloudTranscriptionQuota?
    @State private var isLoadingCloudQuota = false
    @State private var highlightCloudClipLimit = false
    @State private var presentedPrompt: ProcessingOptionsPrompt?
    @State private var permitsBasicTranscription = false
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var account = AccountService.shared
    @Bindable private var llmSettings = LLMSettingsStore.shared

    private var isSingleFile: Bool { mediaURLs.count == 1 }
    private var continueDisabled: Bool {
        (enableTranslation && targetLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (
                computeDestination == .cloud
                    && account.isSignedIn
                    && (isLoadingCloudQuota || cloudAccessError != nil || cloudQuota == nil || cloudQuota?.canAfford != true)
            )
    }

    private var titleText: String {
        let key: String
        switch mode {
        case .upload: key = "Processing options"
        case .retranscribe: key = "Re-transcribe"
        }
        return L10n.string(key)
    }

    private var descriptionText: String {
        let key: String
        switch mode {
        case .upload:
            key = "Optionally clip the media and enable translation before processing."
        case .retranscribe:
            key = "Reprocess the media and replace the transcript after it completes."
        }
        return L10n.string(key)
    }

    private var continueLabel: String {
        if computeDestination == .local, !localModelPlan.missingItems.isEmpty {
            return L10n.string(models.isPreparing(localModelPlan)
                ? "Continue speech setup & transcribe"
                : "Prepare speech features & transcribe")
        }
        let key: String
        switch mode {
        case .upload: key = "Transcribe"
        case .retranscribe: key = "Re-transcribe"
        }
        return L10n.string(key)
    }

    private var placement: TranscriptionPlacement {
        TranscriptionPlacement(
            storage: allowsCloudStorage ? storageDestination : .local,
            compute: computeDestination
        )
    }

    private var localModelPlan: LocalModelInstallPlan {
        models.installPlan(languageCode: languageCode, speakerCount: speakerCount.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                        fileSummary
                        if isSingleFile {
                            titleField
                        }
                        languageField
                        advancedToggle
                        if showAdvanced {
                            advancedSection
                        }
                        placementSection
                        if computeDestination == .local {
                            LocalModelRequirementCard(plan: localModelPlan)
                        }
                        if computeDestination == .cloud {
                            cloudComputeCard
                        }
                        if let cloudAccessError {
                            Text(L10n.display(cloudAccessError))
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Status.errorColor)
                        }
                    }
                    .padding(AppTheme.Spacing.xl)
                }
                .onChange(of: computeDestination) { _, _ in
                    applyCloudDurationClipIfNeeded(proxy: proxy)
                }
                .onChange(of: mediaDurationSeconds) { _, _ in
                    applyCloudDurationClipIfNeeded(proxy: proxy)
                }
                .onChange(of: clipRange) { _, newValue in
                    clampCloudClipIfNeeded(newValue)
                }
            }
            footer
        }
        .frame(width: AppTheme.zoomed(620), height: sheetHeight)
        .background(AppTheme.Background.surfaceColor)
        .onAppear { applyInitialOptionsIfNeeded() }
        .task(id: mediaDurationTaskID) { await loadMediaDuration() }
        .task(id: cloudQuotaTaskID) { await loadCloudQuota() }
        .sheet(item: $presentedPrompt) { prompt in
            switch prompt {
            case .aiUpgrade:
                TranscriptionAIUpgradePrompt {
                    permitsBasicTranscription = true
                    Task { await prepareAndSubmit() }
                }
                .appZoomEnvironment(presentationBoundary: true)
            }
        }
    }

    private var sheetHeight: CGFloat {
        let designHeight: CGFloat
        if isSingleFile, enableClip, showAdvanced {
            designHeight = 720
        } else {
            let base = isSingleFile ? 560.0 : 520.0
            designHeight = computeDestination == .local && !localModelPlan.missingItems.isEmpty
                ? base + 140
                : base
        }
        return AppTheme.zoomed(designHeight)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(titleText)
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                Text(descriptionText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .bold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.zoomed(28), height: AppTheme.zoomed(28))
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.zoomed(8)))
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.xl)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var fileSummary: some View {
        let title = mediaURLs.count == 1
            ? mediaURLs[0].lastPathComponent
            : L10n.format("%@ files selected", mediaURLs.count)
        let detail = mediaURLs.count > 1
            ? L10n.string("Files are processed one at a time to protect memory and GPU.")
            : mediaURLs[0].path
        return HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: mediaURLs.count > 1 ? "doc.on.doc" : "doc")
                .foregroundStyle(Color.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.65), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Session title")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            TextField(L10n.string(key: SessionTitlePolicy.autoGeneratePlaceholder), text: $sessionTitle)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var languageField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input language")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            Menu {
                ForEach(WorkbenchTranscriptionLanguage.allCases) { option in
                    Button {
                        languageCode = option.languageCode
                    } label: {
                        menuItemLabel(option.label, selected: languageCode == option.languageCode)
                    }
                }
            } label: {
                processingMenuLabel(selectedLanguageLabel)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private var selectedLanguageLabel: String {
        WorkbenchTranscriptionLanguage.allCases
            .first(where: { $0.languageCode == languageCode })?
            .label ?? WorkbenchTranscriptionLanguage.automatic.label
    }

    private func processingMenuLabel(_ title: String) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string(key: title))
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.sm)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
        }
        .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(width: AppTheme.Workbench.pickerWidth, height: AppTheme.IconSize.lg, alignment: .leading)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .contentShape(Rectangle())
    }

    private func menuItemLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(L10n.string(key: title))
            Spacer()
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                showAdvanced.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                Text(L10n.string("Advanced settings"))
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            .foregroundStyle(Color.indigo)
        }
        .buttonStyle(.plain)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("Speaker count"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                Menu {
                    ForEach(SpeakerCountOption.allCases) { option in
                        Button {
                            speakerCount = option
                        } label: {
                            menuItemLabel(option.label, selected: speakerCount == option)
                        }
                    }
                } label: {
                    processingMenuLabel(speakerCount.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            Toggle(L10n.string("Segment subtitles"), isOn: $enableSubtitleSegmentation)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .toggleStyle(.checkbox)

            if isSingleFile {
                clipSection
            }

            translationSection
        }
        .padding(.top, AppTheme.Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Toggle(isOn: clipEnabledBinding) {
                Text(L10n.string(requiresCloudDurationClip ? "Clip (required for cloud)" : "Clip (optional)"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            }
            .toggleStyle(.checkbox)
            .disabled(requiresCloudDurationClip)
            if requiresCloudDurationClip {
                Text(L10n.display(RecordingDurationLimit.cloudClipNotice(hasFeatureAccess: account.hasFeatureAccess)))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enableClip {
                Text(L10n.string("Select a time range. The session keeps only this portion."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                ClipRangeControl(
                    mediaURL: mediaURLs[0],
                    range: $clipRange,
                    expandsPlaceholderRange: !hasExplicitClipRange
                )
                    .padding(AppTheme.Spacing.md)
                    .background(AppTheme.Background.baseColor.opacity(0.45), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.45), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(
                    highlightCloudClipLimit ? AppTheme.Status.warningColor : AppTheme.Border.subtleColor,
                    lineWidth: highlightCloudClipLimit ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                )
        }
        .id(AppTheme.Workbench.cloudClipAnchor)
    }

    private var clipEnabledBinding: Binding<Bool> {
        Binding(
            get: { enableClip },
            set: { newValue in
                enableClip = requiresCloudDurationClip ? true : newValue
            }
        )
    }

    private var requiresCloudDurationClip: Bool {
        guard !allowsCloudStorage, computeDestination == .cloud, isSingleFile else { return false }
        guard let duration = mediaDurationSeconds else { return false }
        return RecordingDurationLimit.exceedsLimit(duration, hasFeatureAccess: account.hasFeatureAccess)
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Toggle(isOn: $enableTranslation) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable translation")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    Text("Translate the transcript to the selected language when enabled.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .toggleStyle(.checkbox)

            if enableTranslation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target language")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    Menu {
                        Button {
                            targetLanguageCode = ""
                        } label: {
                            menuItemLabel("Select language", selected: targetLanguageCode.isEmpty)
                        }
                        ForEach(WorkbenchTranscriptionLanguage.allCases.filter {
                            $0.languageCode != nil && $0.languageCode != languageCode
                        }) { option in
                            Button {
                                targetLanguageCode = option.languageCode ?? ""
                            } label: {
                                menuItemLabel(
                                    option.label,
                                    selected: targetLanguageCode == option.languageCode
                                )
                            }
                        }
                    } label: {
                        processingMenuLabel(targetLanguageLabel)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.45), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
        .onChange(of: enableTranslation) { _, enabled in
            if !enabled { targetLanguageCode = "" }
            else if showAdvanced == false { showAdvanced = true }
        }
    }

    private var targetLanguageLabel: String {
        guard !targetLanguageCode.isEmpty else { return "Select language" }
        return WorkbenchTranscriptionLanguage.allCases
            .first(where: { $0.languageCode == targetLanguageCode })?
            .label ?? "Select language"
    }

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if allowsCloudStorage {
                cloudPlacementToggle(
                    title: TaskPlacementCopy.keepSessionTitle,
                    detail: "Keep an editable cloud session you can reopen on other devices.",
                    isOn: cloudStorageBinding
                )
            }
            cloudPlacementToggle(
                title: TaskPlacementCopy.processWithTitle,
                detail: "Transcribe without downloading local resources to this Mac.",
                isOn: cloudComputeBinding
            )
        }
    }

    private var cloudStorageBinding: Binding<Bool> {
        Binding(
            get: { storageDestination == .cloud },
            set: { storageDestination = $0 ? .cloud : .local }
        )
    }

    private var cloudComputeBinding: Binding<Bool> {
        Binding(
            get: { computeDestination == .cloud },
            set: { computeDestination = $0 ? .cloud : .local }
        )
    }

    private func cloudPlacementToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string(key: title))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                Text(L10n.display(detail))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var cloudComputeCard: some View {
        switch CloudTranscriptionNoticePolicy.notice(
            isSignedIn: account.isSignedIn,
            hasFeatureAccess: account.hasFeatureAccess,
            quota: cloudQuota
        ) {
        case .signIn:
            cloudNotice(
                title: "VoxStudio Cloud",
                detail: TaskPlacementCopy.cloudAccountRequired,
                color: AppTheme.Accent.primary
            )
        case .freeUpgrade:
            cloudNotice(
                title: "Transcribe in VoxStudio Cloud",
                detail: TaskPlacementCopy.freeCloudUpgrade,
                color: AppTheme.Accent.primary
            )
        case .insufficientCredits:
            if let cloudQuota {
                cloudNotice(
                    title: "More credits are required",
                    detail: insufficientCreditCopy(cloudQuota),
                    color: AppTheme.Status.warningColor
                )
            }
        case .lowBalance(let remaining):
            cloudNotice(
                title: "Cloud credit balance",
                detail: L10n.format(
                    "After this media, your balance covers about %@ more of this cloud workflow.",
                    CloudTranscriptionQuota.formatDuration(remaining)
                ),
                color: AppTheme.Status.warningColor
            )
        case .none:
            if isLoadingCloudQuota {
                cloudNotice(
                    title: "VoxStudio Cloud",
                    detail: "Checking your cloud credit balance…",
                    color: AppTheme.Accent.primary
                )
            } else if cloudAccessError != nil {
                cloudNotice(
                    title: "VoxStudio Cloud",
                    detail: TaskPlacementCopy.cloudCreditsUnavailable,
                    color: AppTheme.Status.warningColor
                )
            } else {
                EmptyView()
            }
        }
    }

    private func cloudNotice(title: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(L10n.string(key: title))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            Text(L10n.display(detail))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(color.opacity(AppTheme.Opacity.subtle), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg)
                .strokeBorder(color.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
        }
    }

    private func insufficientCreditCopy(_ quota: CloudTranscriptionQuota) -> String {
        let available = quota.affordableMediaSeconds
            .map(CloudTranscriptionQuota.formatDuration) ?? L10n.string("no remaining time")
        let media = CloudTranscriptionQuota.formatDuration(quota.durationSeconds)
        return L10n.format(
            "This media is %@, but your balance covers about %@. Upgrade to Pro or add credits to continue in the Cloud.",
            media,
            available
        )
    }

    private var footer: some View {
        HStack {
            if isPreparingCloud {
                Text(L10n.string(TaskPlacementCopy.checkingCloudAccount))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            Spacer()
            Button(L10n.string("Cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(continueLabel) {
                Task { await prepareAndSubmit() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(continueDisabled || isPreparingCloud)
            .keyboardShortcut(.defaultAction)
        }
        .padding(AppTheme.Spacing.xl)
        .background(AppTheme.Background.surfaceColor.opacity(0.96))
        .overlay(alignment: .top) { Divider() }
    }

    private func applyInitialOptionsIfNeeded() {
        guard !didApplyInitialOptions, let initialOptions else { return }
        didApplyInitialOptions = true
        languageCode = initialOptions.languageCode
        sessionTitle = initialOptions.customTitle ?? ""
        speakerCount = initialOptions.speakerCount
        enableSubtitleSegmentation = initialOptions.useLLMSubtitleProcessing ?? false
        enableTranslation = initialOptions.enableTranslation
            || !(initialOptions.normalizedTargetLanguageCode ?? "").isEmpty
        targetLanguageCode = initialOptions.normalizedTargetLanguageCode ?? ""
        storageDestination = allowsCloudStorage ? initialPlacement.storage : .local
        computeDestination = initialPlacement.compute
        if let startMs = initialOptions.clipStartMs, let endMs = initialOptions.clipEndMs, endMs > startMs {
            enableClip = true
            clipRange = Double(startMs) / 1000 ... Double(endMs) / 1000
            hasExplicitClipRange = true
            showAdvanced = true
        } else if enableTranslation || enableSubtitleSegmentation {
            showAdvanced = true
        }
    }

    private func currentSubmission() -> TranscriptionSubmission {
        var options = TranscriptionProcessingOptions(
            languageCode: languageCode,
            customTitle: SessionTitlePolicy.normalizedUserTitle(sessionTitle),
            speakerCount: speakerCount,
            enableTranslation: enableTranslation,
            targetLanguageCode: enableTranslation ? targetLanguageCode : nil,
            useLLMSubtitleProcessing: enableSubtitleSegmentation
        )
        if isSingleFile, enableClip {
            options.clipStartMs = Int((clipRange.lowerBound * 1000).rounded())
            options.clipEndMs = Int((clipRange.upperBound * 1000).rounded())
        }
        return TranscriptionSubmission(options: options, placement: placement)
    }

    private func applyCloudDurationClipIfNeeded(proxy: ScrollViewProxy) {
        guard requiresCloudDurationClip, let duration = mediaDurationSeconds else {
            highlightCloudClipLimit = false
            return
        }
        let clamped = RecordingDurationLimit.clampedClipRange(
            duration: duration,
            current: enableClip ? clipRange : nil,
            hasFeatureAccess: account.hasFeatureAccess
        )
        let alreadyApplied =
            showAdvanced
            && enableClip
            && clipRange == clamped
            && highlightCloudClipLimit
        guard !alreadyApplied else { return }
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            showAdvanced = true
            enableClip = true
            clipRange = clamped
            highlightCloudClipLimit = true
        } completion: {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                proxy.scrollTo(AppTheme.Workbench.cloudClipAnchor, anchor: .center)
            }
        }
    }

    private func clampCloudClipIfNeeded(_ range: ClosedRange<Double>) {
        guard requiresCloudDurationClip, let duration = mediaDurationSeconds else { return }
        let clamped = RecordingDurationLimit.clampedClipRange(
            duration: duration,
            current: range,
            hasFeatureAccess: account.hasFeatureAccess
        )
        if clamped != range {
            clipRange = clamped
        }
    }

    private var requestedCloudDurationSeconds: Double? {
        if isSingleFile,
           enableClip,
           clipRange.upperBound > clipRange.lowerBound {
            return clipRange.upperBound - clipRange.lowerBound
        }
        return mediaDurationSeconds
    }

    private var mediaDurationTaskID: String {
        mediaURLs.map(\.path).joined(separator: "|")
    }

    private var cloudQuotaTaskID: String {
        let duration = requestedCloudDurationSeconds.map { String(format: "%.3f", $0) } ?? "unknown"
        return [
            computeDestination.rawValue,
            enableTranslation ? targetLanguageCode : "",
            duration,
            account.isSignedIn.description,
            String(account.cloudBillingBalance?.availableCredits ?? -1),
        ].joined(separator: "|")
    }

    private func loadMediaDuration() async {
        let urls = mediaURLs
        let task: Task<Double?, Error> = Task.detached(priority: .userInitiated) {
            var result = 0.0
            for url in urls {
                try Task.checkCancellation()
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard duration.isFinite, duration > 0 else { return nil }
                result += duration
            }
            return result > 0 ? result : nil
        }
        do {
            let total = try await task.value
            guard !Task.isCancelled else { return }
            mediaDurationSeconds = total
        } catch is CancellationError {
            return
        } catch {
            mediaDurationSeconds = nil
        }
    }

    private func loadCloudQuota() async {
        guard computeDestination == .cloud,
              account.isSignedIn,
              let duration = requestedCloudDurationSeconds,
              duration.isFinite,
              duration > 0
        else {
            cloudQuota = nil
            isLoadingCloudQuota = false
            return
        }
        isLoadingCloudQuota = true
        cloudAccessError = nil
        defer { isLoadingCloudQuota = false }
        do {
            cloudQuota = try await account.cloudTranscriptionQuota(
                durationSeconds: duration,
                includesTranslation: enableTranslation,
                includesVocalRepair: false,
                sourceUsageType: CloudTranscriptionQuota.uploadUsageType
            )
        } catch is CancellationError {
            return
        } catch {
            cloudQuota = nil
            cloudAccessError = TaskPlacementCopy.cloudCreditsUnavailable
        }
    }

    private func refreshCloudQuotaBeforeSubmission() async -> Bool {
        guard computeDestination == .cloud else { return true }
        guard let duration = requestedCloudDurationSeconds,
              duration.isFinite,
              duration > 0
        else {
            return true
        }
        do {
            let quota = try await account.cloudTranscriptionQuota(
                durationSeconds: duration,
                includesTranslation: enableTranslation,
                includesVocalRepair: false,
                sourceUsageType: CloudTranscriptionQuota.uploadUsageType
            )
            cloudQuota = quota
            if !quota.canAfford {
                cloudAccessError = insufficientCreditCopy(quota)
                return false
            }
            return true
        } catch {
            cloudAccessError = "Could not verify the cloud credit balance. Try again."
            return false
        }
    }

    private func prepareAndSubmit() async {
        guard !isPreparingCloud else { return }
        cloudAccessError = nil
        if placement.compute == .local,
           localModelPlan.missingItems.contains(where: {
               $0.requiresLicenseAcceptance && !models.isLicenseAccepted($0.id)
           }) {
            models.presentManager()
            return
        }
        if placement.compute == .local, !permitsBasicTranscription {
            _ = await llmSettings.credentialAvailable()
            guard !TranscriptionAIAccessPromptPolicy.shouldPresent(
                compute: placement.compute,
                hasUsableLLM: llmSettings.hasUsableModel(for: .subtitleProcessing)
            ) else {
                presentedPrompt = .aiUpgrade
                return
            }
        }
        if placement.needsAuthentication {
            isPreparingCloud = true
            let result: CloudAccessPreparation
            if let onPrepareCloud {
                result = await onPrepareCloud(placement)
            } else {
                result = await AccountService.shared.ensureCloudAccess()
            }
            isPreparingCloud = false
            switch result {
            case .ready:
                break
            case .cancelled:
                return
            case .failed(let message):
                cloudAccessError = message
                return
            }
        }
        guard await refreshCloudQuotaBeforeSubmission() else { return }
        submitCurrentOptions()
    }

    private func submitCurrentOptions() {
        onContinue(currentSubmission())
    }
}

private enum ProcessingOptionsPrompt: String, Identifiable {
    case aiUpgrade

    var id: String { rawValue }
}
