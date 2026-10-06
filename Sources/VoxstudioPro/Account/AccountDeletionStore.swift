import Foundation
import Observation

@MainActor @Observable
final class AccountDeletionStore {
    private(set) var isDeleting = false
    private(set) var errorMessage: String?
    private(set) var wasScheduled = false
    private let delete: (UUID) async throws -> Void

    init(delete: @escaping (UUID) async throws -> Void = {
        try await AccountService.shared.deleteAccount(expectedUserID: $0)
    }) {
        self.delete = delete
    }

    func deleteAccount(userID: UUID) async {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        wasScheduled = false
        defer { isDeleting = false }
        do {
            try await delete(userID)
            wasScheduled = true
        } catch is CancellationError {
            // An account change invalidates this confirmation.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
