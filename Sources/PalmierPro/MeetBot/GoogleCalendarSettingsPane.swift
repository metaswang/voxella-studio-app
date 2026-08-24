import SwiftUI

@MainActor
struct GoogleCalendarSettingsPane: View {
    @State private var store = GoogleCalendarSettingsStore()
    @State private var showAccessPrompt = false

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            if store.access == .allowed {
                connectionSection(store: $store)
                automationSection(store: $store)
                privacySection
            } else if store.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AppTheme.Spacing.xxl)
            } else {
                FeatureAccessPrompt(
                    feature: .calendarSettings,
                    access: store.access,
                    onRetry: { retryAccess() }
                )
                .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.mdLg)
            }
        }
        .task {
            await store.load()
            showAccessPrompt = store.access != .allowed
        }
        .onChange(of: store.access) { _, access in
            if access == .allowed {
                showAccessPrompt = false
            } else if !store.isLoading {
                showAccessPrompt = true
            }
        }
        .sheet(isPresented: $showAccessPrompt) {
            FeatureAccessPrompt(
                feature: .calendarSettings,
                access: store.access,
                onRetry: { retryAccess() }
            )
            .frame(minWidth: AppTheme.Settings.contentMaxWidth)
        }
    }

    private func connectionSection(store: Bindable<GoogleCalendarSettingsStore>) -> some View {
        SettingsSection(title: L10n.string("Google Calendar")) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "calendar")
                    .font(.system(size: AppTheme.IconSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(store.wrappedValue.status?.googleEmail ?? L10n.string("Not connected"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(store.wrappedValue.status?.connected == true
                        ? L10n.string("Connected")
                        : L10n.string("Disconnected"))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(store.wrappedValue.status?.connected == true
                            ? AppTheme.Status.successColor
                            : AppTheme.Text.tertiaryColor)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                Button {
                    Task { await store.wrappedValue.connect() }
                } label: {
                    Text(store.wrappedValue.isConnecting
                        ? L10n.string("Authorizing…")
                        : store.wrappedValue.status?.connected == true
                            ? L10n.string("Reconnect Google Calendar")
                            : L10n.string("Connect Google Calendar"))
                }
                .buttonStyle(.capsule(.prominent, size: .small))
                .disabled(store.wrappedValue.isConnecting)

                if store.wrappedValue.status?.connected == true {
                    Button(L10n.string("Disconnect")) {
                        Task { await store.wrappedValue.disconnect() }
                    }
                    .buttonStyle(.capsule(.secondary, size: .small))
                    .disabled(store.wrappedValue.isSaving)
                }
            }

            if let error = store.wrappedValue.errorMessage {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func automationSection(store: Bindable<GoogleCalendarSettingsStore>) -> some View {
        SettingsSection(title: L10n.string("Meet Bot automation")) {
            SettingsToggleRow(
                title: L10n.string("Enable automation"),
                subtitle: L10n.string("Allow the bot workflow to use the matching meetings discovered from Google Calendar."),
                isOn: store.rules.enabled
            )

            HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Join rule"))
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("Choose which calendar meetings are eligible for automation."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Picker("", selection: store.rules.mode) {
                    Text(L10n.string("Manual only")).tag("manual")
                    Text(L10n.string("All meetings")).tag("all")
                    Text(L10n.string("Title prefix")).tag("title_prefix")
                }
                .labelsHidden()
                .frame(width: AppTheme.Settings.providerListWidth)
            }

            if store.wrappedValue.rules.mode == "title_prefix" {
                TextField(
                    L10n.string("Title prefix"),
                    text: Binding(
                        get: { store.wrappedValue.rules.titlePrefix ?? "" },
                        set: { store.wrappedValue.rules.titlePrefix = $0.isEmpty ? nil : $0 }
                    )
                )
                    .textFieldStyle(.roundedBorder)
            }

            TextField(
                L10n.string("Default bot display name"),
                text: Binding(
                    get: { store.wrappedValue.rules.botDisplayName ?? "" },
                    set: { store.wrappedValue.rules.botDisplayName = $0.isEmpty ? nil : $0 }
                )
            )
                .textFieldStyle(.roundedBorder)

            SettingsToggleRow(
                title: L10n.string("Record meeting screen"),
                subtitle: L10n.string("Include a meeting video artifact when the bot joins from Google Calendar."),
                isOn: store.rules.recordScreen
            )

            HStack {
                Spacer(minLength: 0)
                Button {
                    Task { await store.wrappedValue.save(rules: store.wrappedValue.rules) }
                } label: {
                    Text(store.wrappedValue.isSaving ? L10n.string("Saving…") : L10n.string("Save automation"))
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(
                    store.wrappedValue.isSaving
                        || store.wrappedValue.isConnecting
                        || store.wrappedValue.status?.connected != true
                )
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(title: L10n.string("Google Calendar data use")) {
            Text(L10n.string("VoxStudio requests read-only Google Calendar access. Calendar data is used only to discover supported meeting links and show event metadata for workflows you choose or enable. It is not used to access meeting audio, video, chat, screen sharing, Drive recordings, Gmail, or contacts."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func retryAccess() {
        Task { @MainActor in
            await store.load()
        }
    }
}
