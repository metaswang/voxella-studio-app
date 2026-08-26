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
    @Bindable private var models = LocalModelManager.shared
    @Bindable private var account = AccountService.shared

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
        switch mode {
        case .upload: "Processing options"
        case .retranscribe: "Re-transcribe and rebuild subtitles"
        }
    }

    private var descriptionText: String {
        switch mode {
        case .upload:
            "Optionally clip the media and enable translation before processing."
        case .retranscribe:
            "Reprocess the media and replace the transcript and subtitles only after it completes."
        }
    }

    private var continueLabel: String {
        switch mode {
        case .upload: "Transcribe"
        case .retranscribe: "Re-transcribe and rebuild"
        }
    }

    private var placement: TranscriptionPlacement {
        TranscriptionPlacement(
            storage: allowsCloudStorage ? storageDestination : .local,
            compute: computeDestination
        )
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
                        computeDetail
                        if let cloudAccessError {
                            Text(cloudAccessError)
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
        .frame(width: 620, height: sheetHeight)
        .background(AppTheme.Background.surfaceColor)
        .colorScheme(.dark)
        .onAppear { applyInitialOptionsIfNeeded() }
        .task(id: mediaDurationTaskID) { await loadMediaDuration() }
        .task(id: cloudQuotaTaskID) { await loadCloudQuota() }
    }

    private var sheetHeight: CGFloat {
        if isSingleFile, enableClip, showAdvanced {
            return 920
        }
        return isSingleFile ? 780 : 720
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.xl)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var fileSummary: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: mediaURLs.count > 1 ? "doc.on.doc" : "doc")
                .foregroundStyle(Color.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(mediaURLs.count == 1
                      ? mediaURLs[0].lastPathComponent
                      : "\(mediaURLs.count) files selected")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                Text(mediaURLs.count > 1
                      ? "Files are processed one at a time to protect memory and GPU."
                      : mediaURLs[0].path)
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
            TextField(SessionTitlePolicy.autoGeneratePlaceholder, text: $sessionTitle)
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
            Text(title)
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
            Text(title)
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
                Text("Advanced settings")
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            .foregroundStyle(Color.indigo)
        }
        .buttonStyle(.plain)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker count")
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
                Text(requiresCloudDurationClip ? "Clip (required for cloud)" : "Clip (optional)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            }
            .toggleStyle(.checkbox)
            .disabled(requiresCloudDurationClip)
            if requiresCloudDurationClip {
                Text(RecordingDurationLimit.cloudClipNotice(isPaid: account.isPaid))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enableClip {
                Text("Select a time range. The session keeps only this portion.")
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
        return RecordingDurationLimit.exceedsLimit(duration, isPaid: account.isPaid)
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
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: 1)
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
                detail: "Transcribe without downloading models to this Mac.",
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
                Text(title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var computeDetail: some View {
        Group {
            if computeDestination == .local {
                localComputeCard
            } else {
                cloudComputeCard
            }
        }
    }

    private var localComputeCard: some View {
        let plan = models.installPlan(
            languageCode: languageCode,
            speakerCount: speakerCount.count
        )
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Models for this Mac")
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            ForEach(plan.items) { item in
                HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                    Image(systemName: item.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(item.isInstalled ? AppTheme.Status.successColor : Color.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        Text("\(item.purpose) · \(item.sizeLabel) · \(item.license)")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                        if item.requiresLicenseAcceptance, !item.isInstalled {
                            Text("License acceptance required before download.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Status.warningColor)
                        }
                    }
                    Spacer()
                }
            }
            if !plan.missingItems.isEmpty {
                Text(plan.additionalDiskSpaceLabel)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            Button("Local Models…") {
                models.presentManager()
            }
            .buttonStyle(.borderless)
            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
        }
        .padding(AppTheme.Spacing.mdLg)
        .background(AppTheme.Background.raisedColor.opacity(0.55), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
    }

    @ViewBuilder
    private var cloudComputeCard: some View {
        switch CloudTranscriptionNoticePolicy.notice(
            isSignedIn: account.isSignedIn,
            isPaid: account.isPaid,
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
                detail: "After this media, your balance covers about \(CloudTranscriptionQuota.formatDuration(remaining)) more of this cloud workflow.",
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
            Text(title)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
            Text(detail)
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
            .map(CloudTranscriptionQuota.formatDuration) ?? "no remaining time"
        let media = CloudTranscriptionQuota.formatDuration(quota.durationSeconds)
        return "This media is \(media), but your balance covers about \(available). Upgrade to Pro or add credits to continue in the Cloud."
    }

    private var footer: some View {
        HStack {
            if isPreparingCloud {
                Text(TaskPlacementCopy.checkingCloudAccount)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            Spacer()
            Button("Cancel", action: onCancel)
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
        } else if enableTranslation {
            showAdvanced = true
        }
    }

    private func currentSubmission() -> TranscriptionSubmission {
        var options = TranscriptionProcessingOptions(
            languageCode: languageCode,
            customTitle: SessionTitlePolicy.normalizedUserTitle(sessionTitle),
            speakerCount: speakerCount,
            enableTranslation: enableTranslation,
            targetLanguageCode: enableTranslation ? targetLanguageCode : nil
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
            isPaid: account.isPaid
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
            isPaid: account.isPaid
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
                includesTranslation: enableTranslation
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
                includesTranslation: enableTranslation
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
