import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProviderConnectionState: Equatable {
    case untested
    case testing
    case connected
    case failed(String, isRateLimited: Bool)

    var iconName: String {
        switch self {
        case .untested: "circle.dashed"
        case .testing: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed(_, let isRateLimited):
            isRateLimited ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .untested: "Not tested"
        case .testing: "Testing connection…"
        case .connected: "Connected"
        case .failed(let message, _): message
        }
    }
}

struct AISettingsPane: View {
    @Bindable private var settings = LLMSettingsStore.shared
    @Bindable private var graphSettings = KnowledgeGraphSettings.shared
    @Bindable private var connections = ProviderConnectivityStore.shared
    @State private var isAdvancedExpanded = false
    @State private var selectedProviderID: UUID?
    @State private var providerDraft = LLMProviderProfile.defaultOpenAI
    @State private var providerPresetID = "openai"
    @State private var prefixFollowsName = true
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
            DisclosureGroup(L10n.string("Advanced AI service configuration"), isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                    SettingsSection(title: "Providers") {
                        providerConfiguration
                    }
                    SettingsSection(title: "Task Models") {
                        taskModelConfiguration
                    }
                }
                .padding(.top, AppTheme.Spacing.lg)
            }
        }
        .onAppear {
            isAdvancedExpanded = settings.useBYOK
            selectInitialProvider()
            syncRouteDrafts()
            settings.refreshCredentialStatus()
        }
        .onChange(of: settings.useBYOK) { _, isEnabled in
            if isEnabled {
                isAdvancedExpanded = true
            }
        }
        .onDisappear {
            persistDrafts()
        }
        .task { await connections.refresh(settings: settings) }
        .onReceive(NotificationCenter.default.publisher(for: .aiConfigurationDidChange)) { _ in
            Task { await connections.refresh(settings: settings) }
        }
        .confirmationDialog(
            L10n.format("Remove %@?", providerPendingRemoval?.displayName ?? L10n.string("provider")),
            isPresented: Binding(
                get: { providerPendingRemoval != nil },
                set: { if !$0 { providerPendingRemoval = nil } }
            )
        ) {
            Button(L10n.string("Remove Provider and API Key"), role: .destructive) {
                removePendingProvider()
            }
            Button(L10n.string("Cancel"), role: .cancel) {
                providerPendingRemoval = nil
            }
        } message: {
            Text(L10n.string("Model routes that use this provider prefix will remain visible until you update them."))
        }
    }

    private var transportConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Toggle(L10n.string("Use your own API key(BYOK)"), isOn: $settings.useBYOK)
                .toggleStyle(.switch)
                .controlSize(.small)

            Text(transportDescription)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.string("Enable graph recall for Knowledge Base"), isOn: $graphSettings.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            if graphSettings.isEnabled {
                Text(L10n.string("Graph extraction runs in the background for visible indexed sessions and augments recall only."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
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

    private var providerConfiguration: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
                providerList
                Divider()
                providerEditor
            }

            credentialEditor

            if let message = credentialStatusMessage {
                Text(L10n.display(message))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(
                        credentialStatusIsError
                            ? AppTheme.Status.errorColor
                            : AppTheme.Status.successColor
                    )
            }

            connectionTestConfiguration

            if let configurationError = settings.configurationError {
                Label(L10n.display(configurationError), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionTestConfiguration: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.smMd) {
            providerConnectionIndicator(for: providerDraft.id, size: AppTheme.IconSize.md)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(connectionState(for: providerDraft.id).label)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(connectionStateColor(for: providerDraft.id))
                Text(connectionDescription)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let record = connections.records[providerDraft.id] {
                    Text(record.testedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if let error = connections.persistenceError {
                    Text(L10n.string("Could not save connection status:") + " " + error)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button {
                testSelectedProviderConnection()
            } label: {
                Label(
                    connectionState(for: providerDraft.id) == .testing
                        ? L10n.string("Testing…")
                        : L10n.string("Test connection"),
                    systemImage: "bolt.horizontal.circle"
                )
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(!canTestSelectedProvider || connectionState(for: providerDraft.id) == .testing)
            .help(L10n.string("Verify the base URL and API key without sending a generation request."))
        }
        .padding(.top, AppTheme.Spacing.xs)
        .help(connectionState(for: providerDraft.id).label)
    }

    private var connectionDescription: String {
        switch connectionState(for: providerDraft.id) {
        case .untested:
            return isLocalProvider(providerDraft)
                ? L10n.string("Local endpoints may not need an API key. Test the models endpoint to confirm the server is running.")
                : L10n.string("Enter a base URL and API key, then test before using this provider.")
        case .testing:
            return L10n.string("Checking the provider's models endpoint…")
        case .connected:
            return isLocalProvider(providerDraft)
                ? L10n.string("The local models endpoint responded successfully.")
                : L10n.string("The endpoint responded and the API key was accepted.")
        case .failed:
            return L10n.string("Hover the status icon for the full reason, then check the URL or key.")
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
                            providerConnectionIndicator(for: provider.id)
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
                    .help(providerConnectionHelp(for: provider.id))

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
                ForEach(LLMProviderPreset.all) { preset in
                    Button {
                        let id = settings.addProvider(preset: preset)
                        selectProvider(id)
                    } label: {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(preset.name)
                            Text(preset.detail)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                }
            } label: {
                Label(L10n.string("Add Provider"), systemImage: "plus")
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
            settingRow(title: "Provider") {
                Picker(L10n.string("Provider"), selection: $providerPresetID) {
                    ForEach(LLMProviderPreset.all) { preset in
                        Text(preset.name)
                            .tag(preset.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(L10n.string("Choose a preset to fill the provider name, prefix, base URL, and model. Select Custom provider for your own endpoint."))
            }
            settingRow(title: "Name") {
                TextField(L10n.string("Provider name"), text: $providerDraft.displayName)
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
                TextField(L10n.string("Optional model name"), text: $providerDraft.model)
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
        .onChange(of: providerPresetID) { _, presetID in
            applyProviderPreset(presetID)
        }
        .onChange(of: providerDraft.displayName) { _, name in
            guard prefixFollowsName else { return }
            providerDraft.prefix = name.providerPrefix
        }
        .onChange(of: providerDraft.baseURL) { _, baseURL in
            guard let preset = LLMProviderPreset.all.first(where: { $0.id == providerPresetID }),
                  !preset.isCustom else { return }
            let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if preset.baseURL.caseInsensitiveCompare(normalizedBaseURL) != .orderedSame {
                providerPresetID = LLMProviderPreset.custom.id
            }
        }
        .onChange(of: providerDraft.prefix) { _, prefix in
            if prefix != providerDraft.displayName.providerPrefix {
                prefixFollowsName = false
            }
        }
        .onChange(of: providerDraft) { oldValue, newValue in
            let routingChanged = oldValue.openRouterRouting != newValue.openRouterRouting
            // Selecting another provider row replaces the draft with that
            // provider's persisted profile. Do not invalidate its connection
            // state just because the selected row has a different endpoint.
            // Only edits to the currently selected provider invalidate a
            // previous connectivity result.
            if oldValue.id == newValue.id,
               oldValue.normalizedBaseURL != newValue.normalizedBaseURL {
                connections.invalidate(newValue.id)
            }
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
                    maskedAPIKey.isEmpty ? L10n.string("Paste a new API key") : maskedAPIKey,
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
                    .help(L10n.string("Remove API key"))
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
            Text(L10n.string("Use provider/model identifiers. Requests retry the active model, then move through fallback models in order."))
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
                Text(L10n.string(key: useCase.title))
                    .font(.system(
                        size: AppTheme.FontSize.md,
                        weight: AppTheme.FontWeight.medium
                    ))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string(key: useCase.detail))
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
                    L10n.format("Timeout: %@s", String(Int(draft.wrappedValue.policy.timeoutSeconds))),
                    value: draft.policy.timeoutSeconds,
                    in: timeoutRange(for: useCase),
                    step: timeoutStep(for: useCase)
                )
                Stepper(
                    L10n.format("Attempts/model: %@", String(draft.wrappedValue.policy.maximumAttemptsPerModel)),
                    value: draft.policy.maximumAttemptsPerModel,
                    in: 1...4
                )
            }
            .font(.system(size: AppTheme.FontSize.sm))

            if let message = routeValidationMessage(for: useCase) {
                Label(L10n.display(message), systemImage: "exclamationmark.triangle.fill")
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
        guard let provider = selectedProvider else { return L10n.string("Select a provider") }
        switch selectedCredentialSaveState {
        case .saving:
            return L10n.format("Saving API key for %@…", provider.displayName)
        case .failed:
            return L10n.format("API key save failed for %@", provider.displayName)
        case .idle, .saved:
            return settings.hasAPIKey(for: provider.id)
                ? L10n.format("API key saved for %@", provider.displayName)
                : L10n.format("No API key saved for %@", provider.displayName)
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
            L10n.string("Saving API key securely…")
        case .saved:
            L10n.string("API key saved securely.")
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

    private func connectionState(for providerID: UUID) -> ProviderConnectionState {
        connections.states[providerID] ?? .untested
    }

    private func connectionStateColor(for providerID: UUID) -> Color {
        switch connectionState(for: providerID) {
        case .untested:
            AppTheme.Text.mutedColor
        case .testing:
            AppTheme.Status.infoColor
        case .connected:
            AppTheme.Status.successColor
        case .failed(_, let isRateLimited):
            isRateLimited ? AppTheme.Status.warningColor : AppTheme.Status.errorColor
        }
    }

    @ViewBuilder
    private func providerConnectionIndicator(for providerID: UUID, size: CGFloat? = nil) -> some View {
        let state = connectionState(for: providerID)
        if state == .testing {
            ProgressView()
                .controlSize(.small)
                .frame(width: size ?? AppTheme.Spacing.smMd, height: size ?? AppTheme.Spacing.smMd)
        } else {
            Image(systemName: state.iconName)
                .font(.system(size: size ?? AppTheme.Spacing.smMd, weight: .semibold))
                .foregroundStyle(connectionStateColor(for: providerID))
                .frame(width: size ?? AppTheme.Spacing.smMd, height: size ?? AppTheme.Spacing.smMd)
        }
    }

    private func providerConnectionHelp(for providerID: UUID) -> String {
        let state = connectionState(for: providerID)
        switch state {
        case .untested:
            return settings.hasAPIKey(for: providerID)
                ? L10n.string("API key saved, but this provider has not been tested yet.")
                : (settings.provider(id: providerID).map(isLocalProvider) == true
                    ? L10n.string("Local endpoint not tested yet. An API key may be blank; test the models endpoint.")
                    : L10n.string("Not ready: add an API key, then test this provider."))
        case .testing:
            return L10n.string("Testing the provider's models endpoint…")
        case .connected:
            return settings.provider(id: providerID).map(isLocalProvider) == true
                ? L10n.string("Connected: the local models endpoint responded successfully.")
                : L10n.string("Connected: the API key was accepted and the models endpoint responded.")
        case .failed(let message, _):
            return L10n.display(message)
        }
    }

    private var canTestSelectedProvider: Bool {
        guard selectedProviderID != nil,
              providerValidationMessage == nil else { return false }
        return !APIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || settings.hasAPIKey(for: providerDraft.id)
            || isLocalProvider(providerDraft)
    }

    private func testSelectedProviderConnection() {
        guard let providerID = selectedProviderID, providerValidationMessage == nil else { return }
        persistProviderIfValid()
        guard let profile = settings.provider(id: providerID) else { return }
        let draftKey = APIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingCredential = true
        statusMessage = nil
        Task { @MainActor in
            defer { isSavingCredential = false }
            do {
                if !draftKey.isEmpty {
                    try await settings.saveAPIKey(draftKey, providerID: providerID)
                    if selectedProviderID == providerID { APIKeyDraft = "" }
                } else if settings.apiKeySaveState(for: providerID) == .saving {
                    throw LLMProviderConnectionError.transport(L10n.string("Wait for the API key to finish saving, then test again."))
                }
                let key = try await settings.loadAPIKey(for: providerID) ?? ""
                await connections.test(profile: profile, key: key, settings: settings)
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private func isLocalProvider(_ profile: LLMProviderProfile) -> Bool {
        LLMProviderPreset.isLocalBaseURL(profile.normalizedBaseURL)
    }

    private func settingRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
            Text(L10n.string(title))
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
        providerPresetID = LLMProviderPreset.matching(provider)?.id ?? LLMProviderPreset.custom.id
        prefixFollowsName = provider.prefix == provider.displayName.providerPrefix
        extraBodyJSONDraft = (try? provider.extraBodyValue.prettyJSONString) ?? "{}"
        extraBodyJSONError = nil
        APIKeyDraft = ""
        maskedAPIKey = ""
        statusMessage = nil
        loadMaskedAPIKey(for: id)
    }

    private func applyProviderPreset(_ presetID: String) {
        guard let preset = LLMProviderPreset.all.first(where: { $0.id == presetID }) else {
            return
        }

        if preset.isCustom {
            providerDraft.provider = .openAICompatible
            return
        }

        guard providerDraft.provider != preset.providerKind
            || providerDraft.displayName != preset.name
            || providerDraft.baseURL != preset.baseURL
            || providerDraft.model != preset.defaultModel
            || providerDraft.prefix != preset.defaultPrefix else {
            return
        }

        providerDraft.provider = preset.providerKind
        providerDraft.displayName = preset.name
        providerDraft.prefix = preset.defaultPrefix
        providerDraft.baseURL = preset.baseURL
        providerDraft.model = preset.defaultModel
        providerDraft.openRouterRouting = preset.providerKind == .openRouter
            ? LLMOpenRouterRouting(enabled: true, sort: .latency)
            : .init()
        prefixFollowsName = true
        if selectedProvider?.normalizedBaseURL != providerDraft.normalizedBaseURL {
            connections.invalidate(providerDraft.id)
        }
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
        connections.invalidate(providerID)
        isSavingCredential = true
        Task {
            defer { isSavingCredential = false }
            do {
                try await settings.deleteAPIKey(providerID: providerID)
                statusIsError = false
                statusMessage = L10n.string("API key removed.")
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
                statusMessage = L10n.string("Provider removed.")
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
        case .subtitleProcessing, .graphExtraction:
            return max(60, minimum)...1_800
        case .skillSelection:
            return minimum...1_800
        case .translation, .chat, .graphQueryUnderstanding:
            return minimum...1_800
        }
    }

    private func timeoutStep(for useCase: LLMUseCase) -> Double {
        useCase == .skillSelection ? 1 : 15
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
        .help(L10n.format("Remove %@", providerName))
        .accessibilityLabel(L10n.format("Remove %@", providerName))
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: AppTheme.Anim.hover), value: isHovered)
    }
}
