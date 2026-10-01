import Foundation

extension Notification.Name {
    static let aiConfigurationDidChange = Notification.Name("voxella.ai.configurationDidChange")
}

enum AITransport: Equatable, Sendable {
    case hosted
    case byok
    case unavailable

    var logLabel: String {
        switch self {
        case .hosted: "hosted"
        case .byok: "byok"
        case .unavailable: "unavailable"
        }
    }
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
        let transport = current
        switch transport {
        case .hosted:
            Log.llm.notice("llm client transport=hosted use_case=\(useCase.rawValue)")
            return VoxellaHostedLLMTextClient(useCase: useCase)
        case .byok:
            do {
                let route = try await LLMSettingsStore.shared.runtimeRoute(for: useCase)
                Log.llm.notice("llm client transport=byok \(route.diagnosticDescription)")
                return ResilientLLMTextClient(route: route)
            } catch {
                Log.llm.warning(
                    "llm client transport=byok use_case=\(useCase.rawValue) failed error=\(LLMDiagnostics.description(error))"
                )
                throw error
            }
        case .unavailable:
            Log.llm.warning("llm client transport=unavailable use_case=\(useCase.rawValue)")
            throw LLMConfigurationError.noConfiguredModel(useCase)
        }
    }
}
