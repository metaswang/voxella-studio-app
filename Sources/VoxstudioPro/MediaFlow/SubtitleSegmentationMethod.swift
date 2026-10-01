import Foundation

enum SubtitleSegmentationMethod: Equatable, Sendable {
    case localCaptions
    case llm
}

extension LLMSettingsStore {
    /// Automatic subtitle segmentation uses BYOK only after the configured
    /// subtitle provider has passed its connection test. Hosted AI access does
    /// not change this choice.
    func subtitleSegmentationMethod(
        connectionStates: [UUID: ProviderConnectionState]
    ) -> SubtitleSegmentationMethod {
        connectedSubtitleProviderIDs(connectionStates: connectionStates).isEmpty ? .localCaptions : .llm
    }

    func connectedSubtitleProviderIDs(
        connectionStates: [UUID: ProviderConnectionState]
    ) -> Set<UUID> {
        guard useBYOK else { return [] }
        return Set(route(for: .subtitleProcessing).modelChain.compactMap { reference in
            guard let parsed = try? Self.parseModelReference(reference),
                  let profile = providers.first(where: {
                      $0.normalizedPrefix.caseInsensitiveCompare(parsed.prefix) == .orderedSame
                  }),
                  (try? profile.validated()) != nil,
                  hasAPIKey(for: profile.id)
            else { return nil }
            return connectionStates[profile.id] == .connected ? profile.id : nil
        })
    }

    func connectedSubtitleClient() async throws -> any LLMTextClient {
        let allowedProviders = connectedSubtitleProviderIDs(connectionStates: ProviderConnectivityStore.shared.states)
        guard !allowedProviders.isEmpty else {
            throw LLMConfigurationError.noConfiguredModel(.subtitleProcessing)
        }
        let route = try await runtimeRoute(for: .subtitleProcessing, allowedProviderIDs: allowedProviders)
        return ResilientLLMTextClient(route: route)
    }
}
