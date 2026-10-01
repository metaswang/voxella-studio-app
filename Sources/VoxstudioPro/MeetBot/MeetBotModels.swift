import Foundation

enum VoxellaMeetBotProvider: String, Decodable, Sendable {
    case google
    case microsoft
    case zoom
}

struct VoxellaCalendarOAuthStart: Decodable, Sendable {
    let authURL: URL
    let state: String
    let expiresIn: Int
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case authURL = "auth_url"
        case state
        case expiresIn = "expires_in"
        case codeVerifier = "code_verifier"
    }
}

struct VoxellaGoogleCalendarRules: Codable, Equatable, Sendable {
    var enabled: Bool
    var calendarID: String
    var mode: String
    var titlePrefix: String?
    var botDisplayName: String?
    var recordScreen: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case calendarID = "calendar_id"
        case mode
        case titlePrefix = "title_prefix"
        case botDisplayName = "bot_display_name"
        case recordScreen = "record_screen"
    }
}

struct VoxellaGoogleCalendarStatus: Decodable, Equatable, Sendable {
    let connected: Bool
    let status: String?
    let googleEmail: String?
    let displayName: String?
    let grantedScopes: [String]
    var rules: VoxellaGoogleCalendarRules?
    let onboardingCompleted: Bool
    let lastCalendarSyncAt: String?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case connected
        case status
        case googleEmail = "google_email"
        case displayName = "display_name"
        case grantedScopes = "granted_scopes"
        case rules
        case onboardingCompleted = "onboarding_completed"
        case lastCalendarSyncAt = "last_calendar_sync_at"
        case lastError = "last_error"
    }

    init(
        connected: Bool,
        status: String? = nil,
        googleEmail: String? = nil,
        displayName: String? = nil,
        grantedScopes: [String] = [],
        rules: VoxellaGoogleCalendarRules? = nil,
        onboardingCompleted: Bool = false,
        lastCalendarSyncAt: String? = nil,
        lastError: String? = nil
    ) {
        self.connected = connected
        self.status = status
        self.googleEmail = googleEmail
        self.displayName = displayName
        self.grantedScopes = grantedScopes
        self.rules = rules
        self.onboardingCompleted = onboardingCompleted
        self.lastCalendarSyncAt = lastCalendarSyncAt
        self.lastError = lastError
    }
}

struct VoxellaGoogleCalendarExchangeResponse: Decodable, Sendable {
    let integration: VoxellaGoogleCalendarStatus
    let bootstrapJobID: String?

    enum CodingKeys: String, CodingKey {
        case integration
        case bootstrapJobID = "bootstrap_job_id"
    }
}

struct VoxellaGoogleCalendarMeeting: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    let calendarID: String
    let eventID: String
    let title: String?
    let startsAt: String?
    let endsAt: String?
    let meetingURL: String?
    let providerKind: String?
    let selectionMode: String?
    let selectionOverride: String?
    let status: String
    let attemptCount: Int
    let lastError: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case calendarID = "calendar_id"
        case eventID = "event_id"
        case title
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case meetingURL = "meeting_url"
        case providerKind = "provider_kind"
        case selectionMode = "selection_mode"
        case selectionOverride = "selection_override"
        case status
        case attemptCount = "attempt_count"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct VoxellaGoogleCalendarMeetingListResponse: Decodable, Sendable {
    let items: [VoxellaGoogleCalendarMeeting]
}

struct VoxellaGoogleCalendarMeetingActionResponse: Decodable, Sendable {
    let meetingID: UUID
    let status: String
    let queuedJobID: String?

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case status
        case queuedJobID = "queued_job_id"
    }
}

struct VoxellaMeetBotJoinResponse: Decodable, Sendable {
    let sessionID: UUID
    let provider: VoxellaMeetBotProvider
    let meetingURL: String
    let title: String?
    let botName: String
    let attendeeBotID: String?
    let attendeeBotState: String?
    let attendeeTranscriptionState: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case provider
        case meetingURL = "meeting_url"
        case title
        case botName = "bot_name"
        case attendeeBotID = "attendee_bot_id"
        case attendeeBotState = "attendee_bot_state"
        case attendeeTranscriptionState = "attendee_transcription_state"
        case createdAt = "created_at"
    }
}
