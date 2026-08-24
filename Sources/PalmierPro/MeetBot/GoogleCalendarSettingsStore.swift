import Foundation
import Observation

@MainActor
@Observable
final class GoogleCalendarSettingsStore {
    private(set) var access: AccountFeatureAccess = .signedOut
    private(set) var status: VoxellaGoogleCalendarStatus?
    private(set) var isLoading = false
    private(set) var isConnecting = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    var rules = VoxellaGoogleCalendarRules(
        enabled: true,
        calendarID: "primary",
        mode: "all",
        titlePrefix: nil,
        botDisplayName: MeetBotStore.defaultBotName,
        recordScreen: true
    )

    @ObservationIgnored private let api = VoxellaAPIClient.shared
    @ObservationIgnored private let oauth = GoogleCalendarOAuthConnector()

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        access = await AccountService.shared.prepareFeatureAccess(.calendarSettings)
        guard access == .allowed else { return }
        do {
            status = try await api.googleCalendarStatus()
            if let remoteRules = status?.rules {
                rules = remoteRules
            }
        } catch {
            handle(error)
        }
    }

    func connect() async {
        guard access == .allowed, !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            status = try await oauth.connect(using: api)
            if let remoteRules = status?.rules {
                rules = remoteRules
            }
        } catch {
            handle(error)
        }
    }

    func save(rules: VoxellaGoogleCalendarRules) async {
        guard access == .allowed, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            status = try await api.updateGoogleCalendarRules(rules)
            if let remoteRules = status?.rules {
                self.rules = remoteRules
            }
        } catch {
            handle(error)
        }
    }

    func disconnect() async {
        guard access == .allowed, status?.connected == true else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await api.disconnectGoogleCalendar()
            status = VoxellaGoogleCalendarStatus(connected: false)
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if let access = MeetBotErrorPresentation.access(for: error, feature: .calendarSettings) {
            self.access = access
            errorMessage = nil
            return
        }
        errorMessage = MeetBotErrorPresentation.message(for: error)
    }
}
