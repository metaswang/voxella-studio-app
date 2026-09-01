import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AISettingsPane: View {
    @Bindable private var settings = LLMSettingsStore.shared
    @State private var selectedProviderID: UUID?
    @State private var providerDraft = LLMProviderProfile.defaultOpenAI
    @State private var extraBodyJSONDraft = "{}"
    @State private var extraBodyJSONError: String?
    @State private var isRequestOverridesExpanded = false
    @State private var routeDrafts: [LLMUseCase: LLMModelRoute] = [:]
    @State private var APIKeyDraft = ""
    @State private var maskedAPIKey = ""
    @State private var isSavingCredential = false
    @State private var providerPendingRemoval: LLMProviderProfile?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case providerName
        case providerPrefix
        case baseURL
        case defaultModel
        case APIKey
        case primaryModel(LLMUseCase)
        case fallbackModels(LLMUseCase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("AI access")) {
                transportConfiguration
            }
            SettingsSection(title: "Providers") {
                providerConfiguration
            }
            SettingsSection(title: L10n.string("Agent Chat BYOK")) {
                agentCredentialsConfiguration
            }
            SettingsSection(title: "Task Models") {
                taskModelConfiguration
            }
        }
        .onAppear {
            selectInitialProvider()
            syncRouteDrafts()
            settings.refreshCredentialStatus()
        }
        .onDisappear {
            persistDrafts()
        }
        .confirmationDialog(
            "Remove \(providerPendingRemoval?.displayName ?? "provider")?",
            isPresented: Binding(
                get: { providerPendingRemoval != nil },
                set: { if !$0 { providerPendingRemoval = nil } }
            )
        ) {
            Button("Remove Provider and API Key", role: .destructive) {
                removePendingProvider()
            }
            Button("Cancel", role: .cancel) {
                providerPendingRemoval = nil
            }
        } message: {
            Text("Model routes that use this provider prefix will remain visible until you update them.")
        }
    }

    private var transportConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Toggle(L10n.string("Use BYOK"), isOn: $settings.useBYOK)
                .toggleStyle(.switch)
                .controlSize(.small)

            Text(transportDescription)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transportDescription: String {
        if settings.useBYOK {
            return AccountService.shared.isSignedIn
                ? L10n.string("You are signed in. You do not need to enable BYOK; your saved keys are currently selected.")
                : L10n.string("BYOK is enabled. Requests use the keys saved below.")
        }
        return AccountService.shared.isSignedIn
            ? L10n.string("Signed-in requests use Voxella AI and consume account credits.")
            : L10n.string("Sign in to use hosted AI, or enable BYOK to use your own keys.")
    }

    private var agentCredentialsConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Text(L10n.string("Use your own provider keys for AI chat. They are stored in the macOS Keychain."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                BYOKAgentKeyRow(provider: provider)
            }
        }
    }

    private var providerConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
                providerList
                Divider()
                providerEditor
            }

            credentialEditor

            if let message = credentialStatusMessage {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(
                        credentialStatusIsError
                            ? AppTheme.Status.errorColor
                            : AppTheme.Status.successColor
                    )
            }

            if let configurationError = settings.configurationError {
                Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(
                "API keys are stored in macOS Keychain. They never enter project files, preferences, or logs.",
                systemImage: "lock.shield"
            )
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(settings.providers) { provider in
                HStack(spacing: AppTheme.Spacing.xs) {
                    Button {
                        selectProvider(provider.id)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Circle()
                                .fill(
                                    settings.hasAPIKey(for: provider.id)
                                        ? AppTheme.Status.successColor
                                        : AppTheme.Text.mutedColor
                                )
                                .frame(
                                    width: AppTheme.Spacing.smMd,
                                    height: AppTheme.Spacing.smMd
                                )
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(provider.displayName)
                                    .font(.system(
                                        size: AppTheme.FontSize.sm,
                                        weight: AppTheme.FontWeight.medium
                                    ))
                                    .foregroundStyle(AppTheme.Text.primaryColor)
                                Text(provider.normalizedPrefix)
                                    .font(.system(
                                        size: AppTheme.FontSize.xs,
                                        design: .monospaced
                                    ))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            }
                            Spacer(minLength: AppTheme.Spacing.sm)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    if settings.providers.count > 1 {
                        ProviderRemoveButton(providerName: provider.displayName) {
                            providerPendingRemoval = provider
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selectedProviderID == provider.id
                        ? AppTheme.Background.raisedColor
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                )
                .contentShape(Rectangle())
            }

            Menu {
                ForEach(LLMProviderKind.allCases) { kind in
                    Button(kind.label) {
                        let id = settings.addProvider(kind: kind)
                        selectProvider(id)
                    }
                }
            } label: {
                Label("Add Provider", systemImage: "plus")
                    .font(.system(
                        size: AppTheme.FontSize.sm,
                        weight: AppTheme.FontWeight.medium
                    ))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(width: AppTheme.Settings.providerListWidth, alignment: .topLeading)
    }

    private var providerEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            settingRow(title: "Name") {
                TextField("Provider name", text: $providerDraft.displayName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .providerName)
            }
            settingRow(title: "Prefix") {
                TextField("provider", text: $providerDraft.prefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .focused($focusedField, equals: .providerPrefix)
            }
            settingRow(title: "Base URL") {
                TextField("https://provider.example/v1", text: $providerDraft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .focused($focusedField, equals: .baseURL)
            }
            settingRow(title: "Default") {
                TextField("Optional model name", text: $providerDraft.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .focused($focusedField, equals: .defaultModel)
            }

            AIRequestOverridesView(
                profile: $providerDraft,
                jsonDraft: $extraBodyJSONDraft,
                jsonError: $extraBodyJSONError,
                isExpanded: $isRequestOverridesExpanded
            )

            if let providerValidationMessage {
                Label(providerValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: providerDraft) { oldValue, newValue in
            let routingChanged = oldValue.openRouterRouting != newValue.openRouterRouting
            persistProviderIfValid()
            if routingChanged {
                syncRouteDrafts()
            }
        }
    }

    private var credentialEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Divider()

            Text(credentialTitle)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(credentialTitleColor)

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(
                    maskedAPIKey.isEmpty ? "Paste a new API key" : maskedAPIKey,
                    text: $APIKeyDraft
                )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .focused($focusedField, equals: .APIKey)
                    .onSubmit { flushCredentialIfReady() }
                    .onPasteCommand(of: [.plainText], perform: pasteCredential)
                    .onChange(of: APIKeyDraft) { _, _ in
                        scheduleCredentialAutosave()
                    }
                    .disabled(isSavingCredential || selectedProviderID == nil)

                if let provider = selectedProvider,
                   settings.hasAPIKey(for: provider.id) {
                    Button(role: .destructive, action: deleteCredential) {
                        Image(systemName: "trash")
                            .frame(
                                width: AppTheme.IconSize.sm,
                                height: AppTheme.IconSize.sm
                            )
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(isSavingCredential)
                    .help("Remove API key")
                }
            }
        }
        .onChange(of: focusedField) { _, field in
            if field != .APIKey {
                flushCredentialIfReady()
            }
        }
        .onChange(of: selectedCredentialSaveState) { _, state in
            guard case .saved = state, let providerID = selectedProviderID else { return }
            loadMaskedAPIKey(for: providerID)
        }
    }

    private var taskModelConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Text("Use provider/model identifiers. Requests retry the active model, then move through fallback models in order.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(LLMUseCase.allCases) { useCase in
                routeEditor(for: useCase)
                if useCase != LLMUseCase.allCases.last {
                    Divider()
                }
            }
        }
    }

    private func routeEditor(for useCase: LLMUseCase) -> some View {
        let draft = routeBinding(for: useCase)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(useCase.title)
                    .font(.system(
                        size: AppTheme.FontSize.md,
                        weight: AppTheme.FontWeight.medium
                    ))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(useCase.detail)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            settingRow(title: "Primary") {
                TextField(
                    "provider/model",
                    text: draft.primaryModel
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .focused($focusedField, equals: .primaryModel(useCase))
            }

            settingRow(title: "Fallbacks") {
                TextField(
                    "provider/model, provider/model",
                    text: fallbackBinding(for: useCase)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .focused($focusedField, equals: .fallbackModels(useCase))
            }

            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                Stepper(
                    "Timeout: \(Int(draft.wrappedValue.policy.timeoutSeconds))s",
                    value: draft.policy.timeoutSeconds,
                    in: timeoutRange(for: useCase),
                    step: 15
                )
                Stepper(
                    "Attempts/model: \(draft.wrappedValue.policy.maximumAttemptsPerModel)",
                    value: draft.policy.maximumAttemptsPerModel,
                    in: 1...4
                )
            }
            .font(.system(size: AppTheme.FontSize.sm))

            if let message = routeValidationMessage(for: useCase) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedProvider: LLMProviderProfile? {
        selectedProviderID.flatMap(settings.provider(id:))
    }

    private var selectedCredentialSaveState: LLMAPIKeySaveState {
        guard let providerID = selectedProviderID else { return .idle }
        return settings.apiKeySaveState(for: providerID)
    }

    private var credentialTitle: String {
        guard let provider = selectedProvider else { return "Select a provider" }
        switch selectedCredentialSaveState {
        case .saving:
            return "Saving API key for \(provider.displayName)…"
        case .failed:
            return "API key save failed for \(provider.displayName)"
        case .idle, .saved:
            return settings.hasAPIKey(for: provider.id)
                ? "API key saved for \(provider.displayName)"
                : "No API key saved for \(provider.displayName)"
        }
    }

    private var credentialTitleColor: Color {
        switch selectedCredentialSaveState {
        case .saving:
            AppTheme.Status.infoColor
        case .failed:
            AppTheme.Status.errorColor
        case .idle, .saved:
            selectedProviderID.map { settings.hasAPIKey(for: $0) } == true
                ? AppTheme.Status.successColor
                : AppTheme.Text.secondaryColor
        }
    }

    private var credentialStatusMessage: String? {
        switch selectedCredentialSaveState {
        case .saving:
            "Saving API key securely…"
        case .saved:
            "API key saved securely."
        case .failed(let message):
            message
        case .idle:
            statusMessage ?? settings.credentialError
        }
    }

    private var credentialStatusIsError: Bool {
        if case .failed = selectedCredentialSaveState { return true }
        return statusIsError || settings.credentialError != nil
    }

    private var providerHasChanges: Bool {
        selectedProvider != providerDraft
    }

    private var providerValidationMessage: String? {
        do {
            _ = try providerDraft.validated()
            if settings.providers.contains(where: {
                $0.id != providerDraft.id
                    && $0.normalizedPrefix.caseInsensitiveCompare(
                        providerDraft.normalizedPrefix
                    ) == .orderedSame
            }) {
                throw LLMConfigurationError.duplicateProviderPrefix(
                    providerDraft.normalizedPrefix
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.Settings.fieldLabelWidth, alignment: .leading)
            content()
        }
    }

    private func selectInitialProvider() {
        let id = selectedProviderID.flatMap(settings.provider(id:))?.id
            ?? settings.providers.first?.id
        if let id { selectProvider(id) }
    }

    private func selectProvider(_ id: UUID) {
        guard let provider = settings.provider(id: id) else { return }
        if let previousProviderID = selectedProviderID, previousProviderID != id {
            flushCredentialIfReady(clearDraft: false)
        }
        selectedProviderID = id
        providerDraft = provider
        extraBodyJSONDraft = (try? provider.extraBodyValue.prettyJSONString) ?? "{}"
        extraBodyJSONError = nil
        APIKeyDraft = ""
        maskedAPIKey = ""
        statusMessage = nil
        loadMaskedAPIKey(for: id)
    }

    private func persistProviderIfValid() {
        guard providerHasChanges else { return }
        guard providerValidationMessage == nil else { return }
        do {
            try settings.updateProvider(providerDraft)
            if let updated = settings.provider(id: providerDraft.id) {
                providerDraft = updated
            }
            if statusIsError {
                statusIsError = false
                statusMessage = nil
            }
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func scheduleCredentialAutosave() {
        guard let providerID = selectedProviderID else { return }
        let snapshot = APIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else {
            settings.cancelPendingAPIKeySave(for: providerID)
            return
        }
        settings.scheduleAPIKeySave(snapshot, providerID: providerID)
    }

    private func pasteCredential(_: [NSItemProvider]) {
        guard let pastedValue = NSPasteboard.general.string(forType: .string) else { return }
        APIKeyDraft = pastedValue
        flushCredentialIfReady()
    }

    private func flushCredentialIfReady(clearDraft: Bool = true) {
        guard let providerID = selectedProviderID else { return }
        persistProviderIfValid()
        if providerValidationMessage != nil { return }
        let key = APIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            settings.scheduleAPIKeySave(key, providerID: providerID)
            if clearDraft {
                APIKeyDraft = ""
            }
        }
        settings.flushAPIKeySave(for: providerID)
    }

    private func loadMaskedAPIKey(for providerID: UUID) {
        Task { @MainActor in
            do {
                let key = try await settings.loadAPIKey(for: providerID)
                guard selectedProviderID == providerID else { return }
                maskedAPIKey = Self.maskedAPIKey(key)
            } catch {
                guard selectedProviderID == providerID else { return }
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private static func maskedAPIKey(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "" }
        let suffix = key.count > 4 ? String(key.suffix(4)) : ""
        return String(repeating: "•", count: suffix.isEmpty ? 32 : 36) + suffix
    }

    private func persistDrafts() {
        flushCredentialIfReady()
        persistProviderIfValid()
        for useCase in LLMUseCase.allCases {
            persistRouteIfValid(useCase)
        }
    }

    private func deleteCredential() {
        guard let providerID = selectedProviderID else { return }
        settings.cancelPendingAPIKeySave(for: providerID)
        APIKeyDraft = ""
        maskedAPIKey = ""
        isSavingCredential = true
        Task {
            defer { isSavingCredential = false }
            do {
                try await settings.deleteAPIKey(providerID: providerID)
                statusIsError = false
                statusMessage = "API key removed."
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private func removePendingProvider() {
        guard let provider = providerPendingRemoval else { return }
        providerPendingRemoval = nil
        settings.cancelPendingAPIKeySave(for: provider.id)
        Task {
            do {
                try await settings.removeProvider(id: provider.id)
                selectInitialProvider()
                statusIsError = false
                statusMessage = "Provider removed."
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private func syncRouteDrafts() {
        routeDrafts = Dictionary(uniqueKeysWithValues: LLMUseCase.allCases.map {
            ($0, settings.route(for: $0))
        })
    }

    private func routeBinding(for useCase: LLMUseCase) -> Binding<LLMModelRoute> {
        Binding(
            get: { routeDrafts[useCase] ?? settings.route(for: useCase) },
            set: { next in
                routeDrafts[useCase] = next
                persistRouteIfValid(useCase)
            }
        )
    }

    private func fallbackBinding(for useCase: LLMUseCase) -> Binding<String> {
        Binding(
            get: {
                routeDrafts[useCase]?.fallbackModels.joined(separator: ", ") ?? ""
            },
            set: { value in
                var route = routeDrafts[useCase] ?? settings.route(for: useCase)
                route.fallbackModels = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                routeDrafts[useCase] = route
                persistRouteIfValid(useCase)
            }
        )
    }

    private func timeoutRange(for useCase: LLMUseCase) -> ClosedRange<Double> {
        let minimum = LLMRequestPolicy.minimumTimeoutSeconds(for: useCase)
        switch useCase {
        case .subtitleProcessing:
            return max(60, minimum)...1_800
        case .translation, .chat:
            return minimum...1_800
        }
    }

    private func routeValidationMessage(for useCase: LLMUseCase) -> String? {
        do {
            let route = routeDrafts[useCase] ?? settings.route(for: useCase)
            _ = try route.policy.validated(for: useCase)
            guard !route.modelChain.isEmpty else {
                throw LLMConfigurationError.missingModel
            }
            for reference in route.modelChain {
                let parsed = try LLMSettingsStore.parseModelReference(reference)
                guard settings.providers.contains(where: {
                    $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
                }) else {
                    throw LLMConfigurationError.missingProvider(parsed.prefix)
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func persistRouteIfValid(_ useCase: LLMUseCase) {
        guard routeValidationMessage(for: useCase) == nil else { return }
        do {
            let route = routeDrafts[useCase] ?? settings.route(for: useCase)
            try settings.updateRoute(route, for: useCase)
            routeDrafts[useCase] = settings.route(for: useCase)
            if statusIsError {
                statusIsError = false
                statusMessage = nil
            }
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

private struct BYOKAgentKeyRow: View {
    let provider: AgentProvider

    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(provider.keyTitle)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Button {
                    NSWorkspace.shared.open(provider.keyURL, configuration: .init(), completionHandler: nil)
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text(provider.keyLinkTitle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(
                    hasKey ? maskedKey : provider.keyPlaceholder,
                    text: $draft
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .focused($isFocused)
                .onSubmit(save)

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(L10n.string("Save"), action: save)
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.large)
                } else if hasKey {
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "trash")
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
                    .help(L10n.string("Remove API key"))
                }
            }
        }
        .onAppear {
            Task { apply(await provider.loadAPIKey()) }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        Task {
            await provider.setAPIKey(key)
            apply(key)
        }
    }

    private func remove() {
        draft = ""
        Task {
            await provider.setAPIKey(nil)
            apply("")
        }
    }

    private func apply(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = key.count > 4
            ? String(repeating: "•", count: 36) + key.suffix(4)
            : String(repeating: "•", count: 32)
    }
}

@MainActor
private extension AgentProvider {
    var keyTitle: String {
        switch self {
        case .anthropic: L10n.string("Anthropic API Key")
        case .openAI: L10n.string("OpenAI API Key")
        }
    }

    var keyLinkTitle: String {
        switch self {
        case .anthropic: L10n.string("Get Anthropic API key")
        case .openAI: L10n.string("Get OpenAI API key")
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        }
    }

    var keyURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

private struct ProviderRemoveButton: View {
    let providerName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .font(.system(
                    size: AppTheme.FontSize.xs,
                    weight: AppTheme.FontWeight.semibold
                ))
                .foregroundStyle(AppTheme.Status.errorColor)
                .frame(
                    width: AppTheme.IconSize.md,
                    height: AppTheme.IconSize.md
                )
                .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
                .scaleEffect(isHovered ? AppTheme.Interaction.hoverScale : 1)
        }
        .buttonStyle(.plain)
        .help("Remove \(providerName)")
        .accessibilityLabel("Remove \(providerName)")
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}
