import Foundation

enum AITransport: Equatable, Sendable {
    case hosted
    case byok
    case unavailable
}

@MainActor
enum AITransportPolicy {
    static var current: AITransport {
        resolve(
            useBYOK: LLMSettingsStore.shared.useBYOK,
            hasHostedAccess: AccountService.shared.aiAllowed
        )
    }

    nonisolated static func resolve(useBYOK: Bool, hasHostedAccess: Bool) -> AITransport {
        if useBYOK { return .byok }
        return hasHostedAccess ? .hosted : .unavailable
    }

    static func makeTextClient(for useCase: LLMUseCase) async throws -> any LLMTextClient {
        switch current {
        case .hosted:
            return VoxellaHostedLLMTextClient(useCase: useCase)
        case .byok:
            let route = try await LLMSettingsStore.shared.runtimeRoute(for: useCase)
            return ResilientLLMTextClient(route: route)
        case .unavailable:
            throw LLMConfigurationError.noConfiguredModel(useCase)
        }
    }
}
