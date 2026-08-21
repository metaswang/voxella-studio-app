@preconcurrency import ConvexMobile

struct VoxellaConvexAuthProvider: AuthProvider {
    typealias T = String

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        let token = try await VoxellaAuthService.shared.authorizedAccessToken()
        onIdToken(token)
        return token
    }

    func logout() async throws {
        // VoxStudio tokens are owned by AccountService. Convex must not clear them.
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        guard let token = try await VoxellaAuthService.shared.validAccessToken() else {
            throw VoxellaAuthError.unauthorized
        }
        onIdToken(token)
        return token
    }

    func extractIdToken(from authResult: String) -> String {
        authResult
    }
}
