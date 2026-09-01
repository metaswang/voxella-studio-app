import SwiftUI

struct AIRequestOverridesView: View {
    @Binding var profile: LLMProviderProfile
    @Binding var jsonDraft: String
    @Binding var jsonError: String?
    @Binding var isExpanded: Bool

    @State private var newProvider = ""

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                if profile.isOpenRouter {
                    openRouterRouting
                    Divider()
                }

                genericExtraBody
            }
            .padding(.top, AppTheme.Spacing.sm)
        } label: {
            Label("Request Overrides", systemImage: "slider.horizontal.3")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
    }

    private var openRouterRouting: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SettingsToggleRow(
                title: "Provider Routing",
                subtitle: "Choose preferred OpenRouter endpoints for this model.",
                isOn: $profile.openRouterRouting.enabled
            )

            if profile.openRouterRouting.enabled {
                providerOrderEditor

                if !profile.openRouterRouting.order.isEmpty {
                    Label(
                        "Explicit provider order takes precedence; :nitro and routing sort are ignored.",
                        systemImage: "info.circle"
                    )
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                }

                SettingsToggleRow(
                    title: "Allow fallbacks",
                    subtitle: "Allow other providers if the preferred providers fail.",
                    isOn: $profile.openRouterRouting.allowFallbacks
                )

                HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                    Text("Routing preference")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Picker(
                        "Routing preference",
                        selection: Binding(
                            get: { profile.openRouterRouting.sort ?? .defaultOrder },
                            set: { profile.openRouterRouting.sort = $0 == .defaultOrder ? nil : $0 }
                        )
                    ) {
                        ForEach(LLMOpenRouterSort.allCases) { sort in
                            Text(sort.label).tag(sort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!profile.openRouterRouting.order.isEmpty)
                }
            }
        }
    }

    private var providerOrderEditor: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Provider order")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            if profile.openRouterRouting.order.isEmpty {
                Text("No preferred providers. OpenRouter will choose the endpoint.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                List {
                    ForEach(profile.openRouterRouting.order.indices, id: \.self) { index in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(AppTheme.Text.mutedColor)
                            Text(profile.openRouterRouting.order[index])
                                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Button {
                                profile.openRouterRouting.order.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .frame(
                                        width: AppTheme.IconSize.xs,
                                        height: AppTheme.IconSize.xs
                                    )
                            }
                            .buttonStyle(.borderless)
                            .help("Remove provider")
                        }
                        .listRowInsets(EdgeInsets(
                            top: AppTheme.Spacing.xs,
                            leading: AppTheme.Spacing.sm,
                            bottom: AppTheme.Spacing.xs,
                            trailing: AppTheme.Spacing.sm
                        ))
                    }
                    .onMove { offsets, destination in
                        profile.openRouterRouting.order.move(
                            fromOffsets: offsets,
                            toOffset: destination
                        )
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: AppTheme.Settings.providerOrderListMinHeight)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("Provider or endpoint slug", text: $newProvider)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .onSubmit(addProvider)
                Button("Add", action: addProvider)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(!canAddProvider)
            }
        }
    }

    private var genericExtraBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Extra Body JSON")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("Additional fields sent with OpenAI-compatible chat completion requests.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            TextEditor(text: $jsonDraft)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(AppTheme.Spacing.sm)
                .frame(minHeight: AppTheme.Settings.extraBodyEditorMinHeight)
                .background(AppTheme.Background.raisedColor, in: RoundedRectangle(
                    cornerRadius: AppTheme.Radius.sm
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(
                            jsonError == nil
                                ? AppTheme.Border.subtleColor
                                : AppTheme.Status.errorColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                }
                .onChange(of: jsonDraft) { _, value in
                    applyJSONDraft(value)
                }

            if let jsonError {
                Label(jsonError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Generated request parameters")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(generatedPreview)
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppTheme.Spacing.sm)
                    .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(
                        cornerRadius: AppTheme.Radius.sm
                    ))
            }
        }
    }

    private var canAddProvider: Bool {
        let value = newProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && !profile.openRouterRouting.order.contains {
                $0.caseInsensitiveCompare(value) == .orderedSame
            }
    }

    private var generatedPreview: String {
        (try? LLMJSONValue.object(profile.resolvedExtraBody).prettyJSONString) ?? "{}"
    }

    private func addProvider() {
        guard canAddProvider else { return }
        profile.openRouterRouting.order.append(
            newProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        newProvider = ""
    }

    private func applyJSONDraft(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            profile.extraBody = [:]
            jsonError = nil
            return
        }
        do {
            profile.extraBody = try LLMJSONValue.parseObject(trimmed)
            jsonError = nil
        } catch let error as LLMRequestOverridesError {
            jsonError = error.localizedDescription
        } catch {
            jsonError = LLMRequestOverridesError.invalidJSON.localizedDescription
        }
    }
}
