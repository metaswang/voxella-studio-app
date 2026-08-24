import Foundation
import Observation

@MainActor
@Observable
final class MeetBotStore {
    static let defaultBotName = "VoxStudio Notetaker"

    private(set) var access: AccountFeatureAccess = .signedOut
    private(set) var isLoading = false
    private(set) var isJoining = false
    private(set) var updatingMeetingID: UUID?
    private(set) var calendarStatus: VoxellaGoogleCalendarStatus?
    private(set) var meetings: [VoxellaGoogleCalendarMeeting] = []
    private(set) var joinResult: VoxellaMeetBotJoinResponse?
    private(set) var errorMessage: String?

    var meetingURL = ""
    var meetingTitle = ""
    var botName = MeetBotStore.defaultBotName
    var recordScreen = false
    var searchText = ""

    @ObservationIgnored private let api = VoxellaAPIClient.shared
    @ObservationIgnored private var loadGeneration = UUID()

    var filteredMeetings: [VoxellaGoogleCalendarMeeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title?.localizedCaseInsensitiveContains(query) == true
                || meeting.meetingURL?.localizedCaseInsensitiveContains(query) == true
        }
    }

    func load() async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        access = await AccountService.shared.prepareFeatureAccess(.meetBot)
        guard loadGeneration == generation, !Task.isCancelled, access == .allowed else { return }

        do {
            let status = try await api.googleCalendarStatus()
            guard loadGeneration == generation, !Task.isCancelled else { return }
            calendarStatus = status
            hydrateBotDefaults(from: status)
        } catch {
            handle(error, feature: .meetBot)
            return
        }

        do {
            let loadedMeetings = try await api.googleCalendarMeetings()
            guard loadGeneration == generation, !Task.isCancelled else { return }
            meetings = loadedMeetings
        } catch {
            handle(error, feature: .meetBot)
        }
    }

    func manualJoin() async {
        errorMessage = nil
        joinResult = nil
        let urlValue = meetingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            errorMessage = L10n.string("Enter a valid meeting link to continue.")
            return
        }

        let normalizedBotName = botName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBotName.isEmpty else {
            errorMessage = L10n.string("Enter a bot display name to continue.")
            return
        }

        isJoining = true
        defer { isJoining = false }
        do {
            joinResult = try await api.manualMeetBotJoin(
                meetingURL: urlValue,
                title: normalizedOptional(meetingTitle),
                botName: normalizedBotName,
                recordScreen: recordScreen
            )
            meetingURL = ""
            meetingTitle = ""
        } catch {
            handle(error, feature: .meetBot)
        }
    }

    func setMeeting(_ meeting: VoxellaGoogleCalendarMeeting, enabled: Bool) async {
        guard updatingMeetingID == nil else { return }
        errorMessage = nil
        updatingMeetingID = meeting.id
        defer { updatingMeetingID = nil }
        do {
            _ = try await api.setGoogleCalendarMeeting(id: meeting.id, enabled: enabled)
            meetings = try await api.googleCalendarMeetings()
        } catch {
            handle(error, feature: .meetBot)
        }
    }

    func retryMeeting(_ meeting: VoxellaGoogleCalendarMeeting) async {
        guard updatingMeetingID == nil else { return }
        errorMessage = nil
        updatingMeetingID = meeting.id
        defer { updatingMeetingID = nil }
        do {
            _ = try await api.retryGoogleCalendarMeeting(id: meeting.id)
            meetings = try await api.googleCalendarMeetings()
        } catch {
            handle(error, feature: .meetBot)
        }
    }

    private func hydrateBotDefaults(from status: VoxellaGoogleCalendarStatus) {
        if let name = status.rules?.botDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           botName == Self.defaultBotName {
            botName = name
        }
        if let recordScreen = status.rules?.recordScreen {
            self.recordScreen = recordScreen
        }
    }

    private func handle(_ error: Error, feature: AccountFeature) {
        if let access = MeetBotErrorPresentation.access(for: error, feature: feature) {
            self.access = access
            errorMessage = nil
            return
        }
        errorMessage = MeetBotErrorPresentation.message(for: error)
    }

    private func normalizedOptional(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
