import Foundation
import Observation

@MainActor @Observable
final class AccountRegistrationStore {
    private(set) var isWorking = false
    private(set) var verificationEmail: String?
    private(set) var errorMessage: String?
    private let register: (String, String) async throws -> VoxellaRegistrationResponse
    private let resend: (String) async throws -> VoxellaRegistrationResponse

    init(
        register: ((String, String) async throws -> VoxellaRegistrationResponse)? = nil,
        resend: ((String) async throws -> VoxellaRegistrationResponse)? = nil
    ) {
        self.register = register ?? { try await VoxellaAPIClient.shared.register(email: $0, password: $1) }
        self.resend = resend ?? { try await VoxellaAPIClient.shared.resendVerification(email: $0) }
    }

    static func isPasswordValid(_ password: String) -> Bool {
        password.count >= 8 && password.contains(where: \.isLetter) && password.contains(where: \.isNumber)
    }

    func createAccount(email: String, password: String) async {
        guard !isWorking, Self.isPasswordValid(password) else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let response = try await register(email.trimmingCharacters(in: .whitespacesAndNewlines), password)
            verificationEmail = response.email
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resendVerification() async {
        guard !isWorking, let verificationEmail else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { _ = try await resend(verificationEmail) }
        catch { errorMessage = error.localizedDescription }
    }

    func reset() {
        guard !isWorking else { return }
        verificationEmail = nil
        errorMessage = nil
    }
}
