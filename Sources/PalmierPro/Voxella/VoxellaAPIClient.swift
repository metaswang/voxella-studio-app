import Foundation

enum VoxellaAPIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case http(Int, String)
    case decoding
    case missingUploadURL
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "VoxStudio sign-in is required for this task."
        case .http(let code, let message):
            message.isEmpty ? "VoxStudio request failed (\(code))." : message
        case .decoding:
            "The VoxStudio response could not be read."
        case .missingUploadURL:
            "VoxStudio did not return an upload URL."
        case .cancelled:
            "The VoxStudio task was cancelled."
        }
    }
}

struct VoxellaSessionCreateResponse: Decodable, Sendable {
    var sessionID: UUID
    var upload: VoxellaSignedUpload?
    var resumable: VoxellaResumableUpload?
    var sseURL: String
    var r2ObjectPath: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case upload
        case resumable
        case sseURL = "sse_url"
        case r2ObjectPath = "r2_object_path"
    }
}

struct VoxellaDesktopSessionSyncResponse: Decodable, Sendable {
    var sessionID: UUID?
    var revision: Int?
    var applied: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case revision
        case applied
    }
}

struct VoxellaSignedUpload: Decodable, Sendable {
    var signedURL: String
    var method: String?
    var headers: [String: String]?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case signedURL = "signed_url"
        case method
        case headers
        case expiresIn = "expires_in"
    }
}

struct VoxellaResumableUpload: Decodable, Sendable {
    var uploadID: UUID
    var partSizeBytes: Int
    var partCount: Int

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id"
        case partSizeBytes = "part_size_bytes"
        case partCount = "part_count"
    }
}

struct VoxellaUploadPartURL: Decodable, Sendable {
    var partNumber: Int
    var signedURL: String
    var method: String?
    var headers: [String: String]?
    var expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case signedURL = "signed_url"
        case method
        case headers
        case expiresIn = "expires_in"
    }
}

struct VoxellaUploadedPart: Decodable, Sendable {
    var partNumber: Int
    var etag: String?
    var sizeBytes: Int?

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case etag
        case sizeBytes = "size_bytes"
    }
}

struct VoxellaUploadStatus: Decodable, Sendable {
    var state: String?
    var parts: [VoxellaUploadedPart]

    enum CodingKeys: String, CodingKey {
        case state
        case parts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        parts = try container.decodeIfPresent([VoxellaUploadedPart].self, forKey: .parts) ?? []
    }
}

struct VoxellaSessionDetail: Decodable, Sendable {
    var id: UUID
    var status: String?
    var currentStage: String?
    var resultReady: Bool?
    var message: String?
    var title: String?
    var sourceLanguage: String?
    var originalFilename: String?
    var artifacts: [String: VoxellaJSONValue]?
    var options: VoxellaSessionOptions?
    var dubSegments: [VoxellaDubSegment]

    var generationID: String? {
        artifacts?["generation_id"]?.stringValue
    }

    var activeWorkflowRunID: String? {
        artifacts?["active_workflow_run_id"]?.stringValue
    }

    var dubProgressSnapshot: [String: VoxellaJSONValue] {
        artifacts?["dub_progress"]?.objectValue ?? [:]
    }

    var mediaReady: Bool {
        artifacts?["media_ready"]?.boolValue == true
    }

    var isClientResultMediaPipeline: Bool {
        artifacts?["media_pipeline_mode"]?.stringValue == "client_results"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case status
        case currentStage = "current_stage"
        case resultReady = "result_ready"
        case message
        case title
        case sourceLanguage = "source_language"
        case originalFilename = "original_filename"
        case artifacts
        case options
        case dubSegments = "dub_segments"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = id
        } else {
            self.id = try container.decode(UUID.self, forKey: .sessionID)
        }
        status = try container.decodeIfPresent(String.self, forKey: .status)
        currentStage = try container.decodeIfPresent(String.self, forKey: .currentStage)
        resultReady = try container.decodeIfPresent(Bool.self, forKey: .resultReady)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        originalFilename = try container.decodeIfPresent(String.self, forKey: .originalFilename)
        artifacts = try container.decodeIfPresent([String: VoxellaJSONValue].self, forKey: .artifacts)
        options = try container.decodeIfPresent(VoxellaSessionOptions.self, forKey: .options)
        dubSegments = try container.decodeIfPresent([VoxellaDubSegment].self, forKey: .dubSegments) ?? []
    }
}

struct VoxellaDubSegment: Decodable, Sendable {
    let index: Int
    let text: String
    let startS: Double
    let endS: Double
    let speakerLabel: String?
    let sourceSubtitleID: Int?

    enum CodingKeys: String, CodingKey {
        case index
        case text
        case startS = "start_s"
        case endS = "end_s"
        case speakerLabel = "speaker_label"
        case sourceSubtitleID = "source_subtitle_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        text = try container.decode(String.self, forKey: .text)
        startS = try container.decodeIfPresent(Double.self, forKey: .startS) ?? 0
        endS = try container.decodeIfPresent(Double.self, forKey: .endS) ?? startS + 0.01
        speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel)
        sourceSubtitleID = try container.decodeIfPresent(Int.self, forKey: .sourceSubtitleID)
    }
}

struct VoxellaDubEstimate: Decodable, Sendable {
    let estimatedDurationSec: Double
    let estimatedCostPoints: Double
    let quotaRemainingPoints: Double
    let maxDurationSecWithRemainingQuota: Double
    let canAfford: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case estimatedDurationSec = "estimated_duration_sec"
        case estimatedCostPoints = "estimated_cost_points"
        case quotaRemainingPoints = "quota_remaining_points"
        case maxDurationSecWithRemainingQuota = "max_duration_sec_with_remaining_quota"
        case canAfford = "can_afford"
        case message
    }
}

struct VoxellaDubSessionCreateResponse: Decodable, Sendable {
    let sessionID: UUID
    let status: String
    let queuedJobID: String?
    let estimatedCredits: Double
    let estimatedDurationSec: Double
    let language: String
    let scriptsCount: Int
    let persistenceScope: RemotePersistenceScope
    let clientCompute: RemoteClientCompute
    let generationID: String?
    let hasPlacementMetadata: Bool
    let hasGenerationMetadata: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case queuedJobID = "queued_job_id"
        case estimatedCredits = "estimated_credits"
        case estimatedDurationSec = "estimated_duration_sec"
        case language
        case scriptsCount = "scripts_count"
        case persistenceScope = "persistence_scope"
        case clientCompute = "client_compute"
        case generationID = "generation_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        queuedJobID = try container.decodeIfPresent(String.self, forKey: .queuedJobID)
        estimatedCredits = try container.decodeIfPresent(Double.self, forKey: .estimatedCredits) ?? 0
        estimatedDurationSec = try container.decodeIfPresent(Double.self, forKey: .estimatedDurationSec) ?? 0
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        scriptsCount = try container.decodeIfPresent(Int.self, forKey: .scriptsCount) ?? 0
        hasPlacementMetadata = container.contains(.persistenceScope) && container.contains(.clientCompute)
        hasGenerationMetadata = container.contains(.generationID)
        persistenceScope = try container.decodeIfPresent(RemotePersistenceScope.self, forKey: .persistenceScope) ?? .persistent
        clientCompute = try container.decodeIfPresent(RemoteClientCompute.self, forKey: .clientCompute) ?? .cloud
        generationID = try container.decodeIfPresent(String.self, forKey: .generationID)
    }
}

struct VoxellaDubClientResultUpload: Decodable, Sendable {
    let uploadID: UUID
    let partSizeBytes: Int
    let partCount: Int

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id"
        case partSizeBytes = "part_size_bytes"
        case partCount = "part_count"
    }
}

struct VoxellaDubClientResultResponse: Decodable, Sendable {
    let sessionID: UUID
    let status: String
    let generationID: String
    let uploadID: UUID
    let objectKey: String
    let segmentCount: Int
    let idempotent: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case generationID = "generation_id"
        case uploadID = "upload_id"
        case objectKey = "object_key"
        case segmentCount = "segment_count"
        case idempotent
    }
}

struct VoxellaDubAudioPlayback: Decodable, Sendable {
    let url: String
    let expiresAt: Double?
    let ttlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case expiresAt = "expires_at"
        case ttlSeconds = "ttl_seconds"
    }
}

struct VoxellaDubReferenceAudio: Decodable, Sendable {
    let id: UUID
    let r2ObjectKey: String
    let durationSec: Double
    let mimeType: String

    enum CodingKeys: String, CodingKey {
        case id
        case r2ObjectKey = "r2_object_key"
        case durationSec = "duration_sec"
        case mimeType = "mime_type"
    }
}

struct VoxellaSessionOptions: Decodable, Sendable {
    let clientCompute: RemoteClientCompute?

    enum CodingKeys: String, CodingKey {
        case clientCompute = "client_compute"
    }
}

enum VoxellaSessionReadiness {
    static func isResultReady(
        status: String?,
        currentStage: String?,
        resultReady: Bool?
    ) -> Bool {
        guard normalized(status) == "completed" else { return false }
        if let resultReady { return resultReady }
        return ["postprocess", "dub"].contains(normalized(currentStage))
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct VoxellaUploadCompleteResponse: Decodable, Sendable {
    var sessionID: UUID
    var status: String?
    var queuedJobID: String?
    var nextEvent: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case queuedJobID = "queued_job_id"
        case nextEvent = "next_event"
    }
}

struct VoxellaCloudUploadOutcome: Sendable {
    let sessionID: UUID
    let workflowRunID: String?
}

enum VoxellaJSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: VoxellaJSONValue])
    case array([VoxellaJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: VoxellaJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([VoxellaJSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var objectValue: [String: VoxellaJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

}

struct VoxellaTranscriptSegment: Decodable, Sendable {
    var startS: Double
    var endS: Double
    var text: String
    var speakerLabel: String?
    var words: [VoxellaTranscriptWord]

    enum CodingKeys: String, CodingKey {
        case startS = "start_s"
        case endS = "end_s"
        case text
        case speakerLabel = "speaker_label"
        case words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startS = try container.decode(Double.self, forKey: .startS)
        endS = try container.decode(Double.self, forKey: .endS)
        text = try container.decode(String.self, forKey: .text)
        speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel)
        words = try container.decodeIfPresent([VoxellaTranscriptWord].self, forKey: .words) ?? []
    }
}

struct VoxellaTranscriptWord: Decodable, Sendable {
    var word: String
    var startS: Double?
    var endS: Double?
    var speaker: String?

    enum CodingKeys: String, CodingKey {
        case word
        case startS = "start_s"
        case endS = "end_s"
        case speaker
    }
}

struct VoxellaSubtitleCue: Decodable, Sendable {
    var startS: Double
    var endS: Double
    var text: String
    var speakerLabel: String?

    enum CodingKeys: String, CodingKey {
        case startS = "start_s"
        case endS = "end_s"
        case text
        case speakerLabel = "speaker_label"
    }
}

struct VoxellaAccountProfile: Decodable, Sendable {
    let id: UUID
    let email: String
    let name: String?
    let pictureURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case pictureURL = "picture_url"
    }
}

struct VoxellaBillingPrice: Decodable, Sendable {
    let billingInterval: String
    let price: Double

    enum CodingKeys: String, CodingKey {
        case billingInterval = "billing_interval"
        case price
    }
}

struct VoxellaBillingPlan: Decodable, Sendable {
    let id: String
    let planCode: String
    let name: String
    let includedCredits: Int
    let usageRates: [VoxellaBillingUsageRate]
    let prices: [VoxellaBillingPrice]

    enum CodingKeys: String, CodingKey {
        case id
        case planCode = "plan_code"
        case name
        case includedCredits = "included_credits"
        case usageRates = "usage_rates"
        case prices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        planCode = try container.decode(String.self, forKey: .planCode)
        name = try container.decode(String.self, forKey: .name)
        includedCredits = try container.decode(Int.self, forKey: .includedCredits)
        usageRates = try container.decodeIfPresent([VoxellaBillingUsageRate].self, forKey: .usageRates) ?? []
        prices = try container.decodeIfPresent([VoxellaBillingPrice].self, forKey: .prices) ?? []
    }
}

struct VoxellaBillingUsageRate: Decodable, Sendable {
    let usageType: String
    let creditsPerSecond: Double

    enum CodingKeys: String, CodingKey {
        case usageType = "usage_type"
        case creditsPerSecond = "credits_per_second"
    }
}

struct VoxellaUserPlans: Decodable, Sendable {
    let userPlanID: String?
    let currentPeriodEnd: String?
    let statusNote: String?
    let plans: [VoxellaBillingPlan]

    enum CodingKeys: String, CodingKey {
        case userPlanID = "user_plan_id"
        case currentPeriodEnd = "current_period_end"
        case statusNote = "status_note"
        case plans
    }
}

struct VoxellaBillingBalance: Decodable, Sendable {
    let availableCredits: Double
    let subscriptionCredits: Double
    let topupCredits: Double
    let grantCredits: Double
    let estimatedSeconds: [String: Double]

    enum CodingKeys: String, CodingKey {
        case availableCredits = "available_credits"
        case subscriptionCredits = "subscription_credits"
        case topupCredits = "topup_credits"
        case grantCredits = "grant_credits"
        case estimatedSeconds = "estimated_seconds"
    }

    init(
        availableCredits: Double,
        subscriptionCredits: Double,
        topupCredits: Double,
        grantCredits: Double,
        estimatedSeconds: [String: Double]
    ) {
        self.availableCredits = availableCredits
        self.subscriptionCredits = subscriptionCredits
        self.topupCredits = topupCredits
        self.grantCredits = grantCredits
        self.estimatedSeconds = estimatedSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCredits = try container.decodeIfPresent(Double.self, forKey: .availableCredits) ?? 0
        subscriptionCredits = try container.decodeIfPresent(Double.self, forKey: .subscriptionCredits) ?? 0
        topupCredits = try container.decodeIfPresent(Double.self, forKey: .topupCredits) ?? 0
        grantCredits = try container.decodeIfPresent(Double.self, forKey: .grantCredits) ?? 0
        estimatedSeconds = try container.decodeIfPresent([String: Double].self, forKey: .estimatedSeconds) ?? [:]
    }
}

struct VoxellaUsageEstimate: Decodable, Sendable {
    let estimatedCredits: Double
    let creditsPerSecond: Double
    let durationSec: Int
    let availableCredits: Double
    let canAfford: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case estimatedCredits = "estimated_credits"
        case creditsPerSecond = "credits_per_second"
        case durationSec = "duration_sec"
        case availableCredits = "available_credits"
        case canAfford = "can_afford"
        case message
    }
}

struct VoxellaCheckoutSession: Decodable, Sendable {
    let checkoutURL: String
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case checkoutURL = "checkout_url"
        case sessionID = "session_id"
    }
}

struct VoxellaPortalSession: Decodable, Sendable {
    let url: String
}

actor VoxellaAPIClient {
    static let shared = VoxellaAPIClient()

    private let auth: VoxellaAuthService
    private let session: URLSession

    init(auth: VoxellaAuthService = .shared, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    func accountProfile() async throws -> VoxellaAccountProfile {
        try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/users/me"),
            method: "GET",
            as: VoxellaAccountProfile.self
        )
    }

    func billingPlans() async throws -> VoxellaUserPlans {
        try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/billing/plans"),
            method: "GET",
            as: VoxellaUserPlans.self
        )
    }

    func billingBalance() async throws -> VoxellaBillingBalance {
        try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/billing/balance"),
            method: "GET",
            as: VoxellaBillingBalance.self
        )
    }

    func summaryTemplateTree(
        scope: String = "all",
        locale: String
    ) async throws -> VoxellaSummaryTemplateTreeResponse {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.apiURL("api/v1/summary-templates/tree"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "locale", value: locale),
        ]
        guard let url = components.url else { throw VoxellaAPIError.decoding }
        return try await request(url: url, method: "GET", as: VoxellaSummaryTemplateTreeResponse.self)
    }

    func summaryTemplate(id: String, locale: String) async throws -> VoxellaSummaryTemplate {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.apiURL("api/v1/summary-templates/\(id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "locale", value: locale)]
        guard let url = components.url else { throw VoxellaAPIError.decoding }
        return try await request(url: url, method: "GET", as: VoxellaSummaryTemplate.self)
    }

    func copySummaryTemplateForEdit(
        id: String,
        reuseExisting: Bool = true
    ) async throws -> VoxellaSummaryTemplate {
        try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/summary-templates/\(id)/copy-for-edit"),
            method: "POST",
            json: ["reuse_existing": reuseExisting],
            as: VoxellaSummaryTemplate.self
        )
    }

    func updateSummaryTemplate(
        id: String,
        name: String?,
        description: String?,
        userEdition: String?
    ) async throws -> VoxellaSummaryTemplateUpdateResponse {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let description { body["description"] = description }
        if let userEdition { body["user_edition"] = userEdition }
        return try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/summary-templates/\(id)"),
            method: "PATCH",
            json: body,
            as: VoxellaSummaryTemplateUpdateResponse.self
        )
    }

    func assistSummaryTemplate(
        id: String,
        instruction: String,
        currentUserEdition: String?
    ) async throws -> VoxellaSummaryTemplateAiEditResponse {
        var body: [String: Any] = ["instruction": instruction]
        if let currentUserEdition { body["current_user_edition"] = currentUserEdition }
        return try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/summary-templates/\(id)/ai-edit"),
            method: "POST",
            json: body,
            as: VoxellaSummaryTemplateAiEditResponse.self
        )
    }

    func generateSessionSummary(
        sessionID: UUID,
        templateID: String?,
        templateUpdate: VoxellaSummaryTemplateUpdatePayload? = nil
    ) async throws -> VoxellaSummaryEnqueueResponse {
        try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "summary/generate"),
            method: "POST",
            json: summaryGenerationBody(templateID: templateID, templateUpdate: templateUpdate),
            as: VoxellaSummaryEnqueueResponse.self
        )
    }

    func regenerateSessionSummary(
        sessionID: UUID,
        templateID: String,
        templateUpdate: VoxellaSummaryTemplateUpdatePayload? = nil
    ) async throws -> VoxellaSummaryEnqueueResponse {
        let normalizedTemplateID = templateID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTemplateID.isEmpty else {
            throw VoxellaAPIError.http(422, "A summary template is required.")
        }
        guard let templateUUID = UUID(uuidString: normalizedTemplateID) else {
            throw VoxellaAPIError.http(422, "The summary template identifier is invalid.")
        }
        let body = summaryGenerationBody(
            templateID: templateUUID.uuidString.lowercased(),
            templateUpdate: templateUpdate
        )
        return try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "summary/regenerate"),
            method: "POST",
            json: body,
            as: VoxellaSummaryEnqueueResponse.self
        )
    }

    func sessionSummary(
        sessionID: UUID,
        locale: String? = nil
    ) async throws -> VoxellaSessionSummaryResponse {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "summary"),
            resolvingAgainstBaseURL: false
        )!
        if let locale, !locale.isEmpty {
            components.queryItems = [URLQueryItem(name: "locale", value: locale)]
        }
        guard let url = components.url else { throw VoxellaAPIError.decoding }
        return try await request(url: url, method: "GET", as: VoxellaSessionSummaryResponse.self)
    }

    func updateSessionSummary(
        sessionID: UUID,
        markdown: String
    ) async throws -> VoxellaSessionSummaryUpdateResponse {
        let normalizedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMarkdown.isEmpty else {
            throw VoxellaAPIError.http(422, "A summary is required.")
        }
        return try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "summary"),
            method: "PUT",
            json: ["summary_markdown": normalizedMarkdown],
            as: VoxellaSessionSummaryUpdateResponse.self
        )
    }

    func usageEstimate(
        durationSeconds: Double,
        usageTypes: [String]
    ) async throws -> VoxellaUsageEstimate {
        let duration = max(1, Int(durationSeconds.rounded(.up)))
        let normalizedTypes = usageTypes.filter { !$0.isEmpty }
        guard !normalizedTypes.isEmpty else {
            throw VoxellaAPIError.http(0, "A cloud usage type is required.")
        }
        var components = URLComponents(
            url: VoxellaAPIConfiguration.apiURL("api/v1/billing/usage/estimate"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = normalizedTypes.map {
            URLQueryItem(name: "usage_type", value: $0)
        } + [
            URLQueryItem(name: "duration_sec", value: String(duration)),
        ]
        guard let url = components.url else {
            throw VoxellaAPIError.http(0, "Could not prepare the cloud credit estimate.")
        }
        return try await request(url: url, method: "GET", as: VoxellaUsageEstimate.self)
    }

    func estimateDub(
        language: String?,
        script: String,
        segments: [String],
        speed: Double = 1
    ) async throws -> VoxellaDubEstimate {
        var body: [String: Any] = [
            "segments": segments,
            "speed": speed,
            "voice_mode": "clone",
            "emotion_profile": "neutral",
        ]
        if let language, !language.isEmpty { body["language"] = language }
        if !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["text"] = script
        }
        return try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/dub/estimate"),
            method: "POST",
            json: body,
            as: VoxellaDubEstimate.self
        )
    }

    func createBillingCheckout(planID: String? = nil, topupAmountUSD: Double? = nil) async throws -> VoxellaCheckoutSession {
        var body: [String: Any] = [
            "interval": "month",
            "success_url": VoxellaAPIConfiguration.baseURL.absoluteString,
            "cancel_url": VoxellaAPIConfiguration.baseURL.absoluteString,
        ]
        if let planID { body["plan_id"] = planID }
        if let topupAmountUSD { body["topup_amount_usd"] = topupAmountUSD }
        return try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/billing/stripe/checkout"),
            method: "POST",
            json: body,
            as: VoxellaCheckoutSession.self
        )
    }

    func createBillingPortal() async throws -> VoxellaPortalSession {
        try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/billing/stripe/portal"),
            method: "POST",
            json: ["return_url": VoxellaAPIConfiguration.baseURL.absoluteString],
            as: VoxellaPortalSession.self
        )
    }

    func createDubSession(
        sessionID: UUID? = nil,
        regenerate: Bool = false,
        language: String,
        script: String,
        segments: [DubSegmentPayload],
        referenceAudioID: UUID?,
        referenceAudioR2Key: String,
        referenceText: String,
        model: DubModelChoice,
        placement: TaskPlacement,
        generationID: String,
        clientRequestID: String,
        title: String?
    ) async throws -> VoxellaDubSessionCreateResponse {
        var body: [String: Any] = [
            "language": language,
            "script": script,
            "segments": segments.map(Self.encodeDubSegment),
            "reference_audio_r2_key": referenceAudioR2Key,
            "ref_text": referenceText,
            "options": [
                "audio_format": "m4a",
                "speed": 1.0,
                "sample_rate": 24_000,
            ],
            "persistence_scope": placement.remotePersistenceScope?.rawValue ?? "persistent",
            "client_compute": placement.compute == .local ? "local" : "cloud",
            "client_request_id": clientRequestID,
            "generation_id": generationID,
        ]
        if let referenceAudioID { body["reference_audio_id"] = referenceAudioID.uuidString }
        if let title, !title.isEmpty { body["title"] = title }
        if regenerate, let sessionID {
            body["regenerate"] = true
            body["session_id"] = sessionID.uuidString
        }
        return try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/dub/sessions"),
            method: "POST",
            json: body,
            as: VoxellaDubSessionCreateResponse.self
        )
    }

    func prepareDubClientResultUpload(
        sessionID: UUID,
        generationID: String,
        filename: String,
        contentType: String,
        sizeBytes: Int64,
        clientUploadID: String
    ) async throws -> VoxellaDubClientResultUpload {
        try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID)
                .appending(path: "client-results/prepare"),
            method: "POST",
            json: [
                "generation_id": generationID,
                "filename": filename,
                "content_type": contentType,
                "size_bytes": sizeBytes,
                "client_upload_id": clientUploadID,
            ],
            as: VoxellaDubClientResultUpload.self
        )
    }

    func submitDubClientResult(
        sessionID: UUID,
        uploadID: UUID,
        generationID: String,
        durationSeconds: Double,
        mimeType: String,
        segments: [DubRenderedSegment],
        resultID: String
    ) async throws -> VoxellaDubClientResultResponse {
        try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "client-results"),
            method: "POST",
            json: [
                "upload_id": uploadID.uuidString,
                "generation_id": generationID,
                "duration_sec": durationSeconds,
                "mime_type": mimeType,
                "segments": segments.map(Self.encodeDubRenderedSegment),
                "result_id": resultID,
            ],
            as: VoxellaDubClientResultResponse.self
        )
    }

    func dubAudioPlaybackURL(sessionID: UUID) async throws -> VoxellaDubAudioPlayback {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.apiURL("api/v1/media/audio"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "session_id", value: sessionID.uuidString),
            URLQueryItem(name: "variant", value: "dub"),
        ]
        guard let url = components.url else { throw VoxellaAPIError.decoding }
        return try await request(url: url, method: "GET", as: VoxellaDubAudioPlayback.self)
    }

    func uploadDubReferenceAudio(
        fileURL: URL,
        name: String,
        languageCode: String,
        gender: String,
        transcript: String
    ) async throws -> VoxellaDubReferenceAudio {
        let audioData = try await Task.detached(priority: .utility) {
            try Data(contentsOf: fileURL)
        }.value
        let fields: [String: String] = [
            "language_code": languageCode,
            "style_key": gender,
            "style_name": name,
            "script": transcript,
        ]
        return try await sendMultipart(
            url: VoxellaAPIConfiguration.apiURL("api/v1/dub/reference-audios"),
            fields: fields,
            fileData: audioData,
            filename: fileURL.lastPathComponent,
            contentType: Self.mimeType(for: fileURL),
            as: VoxellaDubReferenceAudio.self
        )
    }

    func createSession(
        filename: String,
        mimeType: String,
        sizeBytes: Int64?,
        durationHintSec: Double?,
        options: TranscriptionProcessingOptions,
        placement: TranscriptionPlacement,
        clientRequestID: String
    ) async throws -> VoxellaSessionCreateResponse {
        var body: [String: Any] = [
            "filename": filename,
            "mime_type": mimeType,
            "client_request_id": clientRequestID,
            "options": sessionOptions(
                options,
                placement: placement,
                mimeType: mimeType,
                filename: filename,
                durationSec: durationHintSec
            ),
        ]
        if let sizeBytes { body["size_bytes"] = sizeBytes }
        if let durationHintSec, durationHintSec.isFinite, durationHintSec > 0 {
            body["duration_hint_sec"] = max(1, Int(durationHintSec.rounded()))
        }
        return try await request(
            url: VoxellaAPIConfiguration.sessionsURL,
            method: "POST",
            json: body,
            as: VoxellaSessionCreateResponse.self
        )
    }

    func partURL(uploadID: UUID, partNumber: Int) async throws -> VoxellaUploadPartURL {
        try await request(
            url: VoxellaAPIConfiguration.apiURL(
                "api/v1/uploads/\(VoxellaAPIConfiguration.apiIdentifier(uploadID))/parts/\(partNumber)/url"
            ),
            method: "POST",
            json: [:] as [String: Any],
            as: VoxellaUploadPartURL.self
        )
    }

    func completeResumableUpload(uploadID: UUID) async throws {
        struct Empty: Decodable {}
        _ = try await request(
            url: VoxellaAPIConfiguration.apiURL(
                "api/v1/uploads/\(VoxellaAPIConfiguration.apiIdentifier(uploadID))/complete"
            ),
            method: "POST",
            json: [:] as [String: Any],
            as: Empty.self
        )
    }

    func uploadStatus(uploadID: UUID) async throws -> VoxellaUploadStatus {
        try await request(
            url: VoxellaAPIConfiguration.apiURL("api/v1/uploads/\(VoxellaAPIConfiguration.apiIdentifier(uploadID))"),
            method: "GET",
            as: VoxellaUploadStatus.self
        )
    }

    func completeSessionUpload(
        sessionID: UUID,
        durationSec: Double?,
        sizeBytes: Int64?,
        mimeType: String,
        filename: String,
        startPipeline: Bool,
        prepareMedia: Bool = false
    ) async throws -> VoxellaUploadCompleteResponse {
        var body: [String: Any] = [
            "start_pipeline": startPipeline,
        ]
        if prepareMedia {
            body["prepare_media"] = true
        }
        if let sizeBytes { body["size_bytes"] = sizeBytes }
        var optionsOverride = sessionMediaOptions(mimeType: mimeType, filename: filename)
        if let durationSec, durationSec.isFinite, durationSec > 0 {
            optionsOverride["duration_ms"] = Int((durationSec * 1000).rounded())
        }
        if !optionsOverride.isEmpty {
            body["options_override"] = optionsOverride
        }
        if optionsOverride["upload_has_video"] as? Bool == true {
            body["client_meta"] = ["upload_has_video": true]
        }
        return try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "upload-complete"),
            method: "POST",
            json: body,
            as: VoxellaUploadCompleteResponse.self
        )
    }

    func sessionDetail(
        _ sessionID: UUID,
        includeDubSegments: Bool = false
    ) async throws -> VoxellaSessionDetail {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.sessionURL(sessionID),
            resolvingAgainstBaseURL: false
        )!
        if includeDubSegments {
            components.queryItems = [URLQueryItem(name: "include_dub_segments", value: "true")]
        }
        return try await request(
            url: components.url ?? VoxellaAPIConfiguration.sessionURL(sessionID),
            method: "GET",
            as: VoxellaSessionDetail.self
        )
    }

    func transcriptSegments(_ sessionID: UUID) async throws -> [VoxellaTranscriptSegment] {
        struct Envelope: Decodable {
            var items: [VoxellaTranscriptSegment]?
            var segments: [VoxellaTranscriptSegment]?
            var hasNext: Bool?
            var nextCursor: String?

            enum CodingKeys: String, CodingKey {
                case items
                case segments
                case hasNext = "has_next"
                case nextCursor = "next_cursor"
            }
        }

        var allSegments: [VoxellaTranscriptSegment] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            let envelope = try await request(
                url: sessionListURL(sessionID, path: "segments", cursor: cursor, limit: 100),
                method: "GET",
                as: Envelope.self
            )
            allSegments.append(contentsOf: envelope.items ?? envelope.segments ?? [])
            guard envelope.hasNext == true,
                  let nextCursor = envelope.nextCursor,
                  !nextCursor.isEmpty,
                  nextCursor != cursor,
                  seenCursors.insert(nextCursor).inserted
            else {
                return allSegments
            }
            cursor = nextCursor
        }
    }

    func subtitleCues(_ sessionID: UUID) async throws -> [VoxellaSubtitleCue] {
        struct Envelope: Decodable {
            var items: [VoxellaSubtitleCue]?
            var cues: [VoxellaSubtitleCue]?
            var hasNext: Bool?
            var nextCursor: String?

            enum CodingKeys: String, CodingKey {
                case items
                case cues
                case hasNext = "has_next"
                case nextCursor = "next_cursor"
            }
        }

        var allCues: [VoxellaSubtitleCue] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            let envelope = try await request(
                url: sessionListURL(sessionID, path: "subtitle-segments", cursor: cursor, limit: 100),
                method: "GET",
                as: Envelope.self
            )
            allCues.append(contentsOf: envelope.items ?? envelope.cues ?? [])
            guard envelope.hasNext == true,
                  let nextCursor = envelope.nextCursor,
                  !nextCursor.isEmpty,
                  nextCursor != cursor,
                  seenCursors.insert(nextCursor).inserted
            else {
                return allCues
            }
            cursor = nextCursor
        }
    }

    func submitLocalResults(
        sessionID: UUID,
        result: TranscriptionResult,
        subtitleTrack: SubtitleTrack?,
        translationTracks: [WorkbenchTranslationTrack],
        title: String? = nil,
        summary: String? = nil,
        sessionTag: String? = nil
    ) async throws {
        struct Empty: Decodable {}
        let canonicalResult = result.aggregatingSegments()
        var body: [String: Any] = [
            "source_language": canonicalResult.language as Any,
            "transcript_text": canonicalResult.text,
            "segments": canonicalResult.segments.map(Self.encodeSegment),
            "words": canonicalResult.words.map(Self.encodeWord),
            "subtitles": (subtitleTrack?.cues ?? []).map(Self.encodeCue),
            "translations": translationTracks.map { track in
                [
                    "language": track.languageCode,
                    "cues": track.track.cues.map(Self.encodeCue),
                ] as [String: Any]
            },
        ]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["title"] = title
        }
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["summary"] = summary
        }
        if let sessionTag, !sessionTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["session_tag"] = sessionTag
        }
        _ = try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "client-results"),
            method: "POST",
            json: body,
            as: Empty.self
        )
    }

    func syncDesktopSession(
        _ snapshot: CloudSessionSyncSnapshot
    ) async throws -> VoxellaDesktopSessionSyncResponse {
        let canonicalResult = snapshot.result.aggregatingSegments()
        let sourceLanguage = canonicalResult.language ?? snapshot.sourceLanguage
        let body: [String: Any] = [
            "content_kind": snapshot.contentKind.rawValue,
            "client_revision": snapshot.revision,
            "source_language": sourceLanguage ?? NSNull(),
            "transcript_text": canonicalResult.text,
            "segments": canonicalResult.segments.map(Self.encodeSegment),
            "words": canonicalResult.words.map(Self.encodeWord),
            "subtitles": (snapshot.subtitleTrack?.cues ?? []).map(Self.encodeCue),
            "translations": snapshot.translationTracks.map { track in
                [
                    "language": track.languageCode,
                    "cues": track.track.cues.map(Self.encodeCue),
                ] as [String: Any]
            },
            "dub_segments": snapshot.dubSegments.map(Self.encodeDubSegment),
            "title": Self.optionalTextValue(snapshot.title),
            "summary": Self.optionalTextValue(snapshot.summary),
            "summary_template_id": Self.optionalTextValue(snapshot.summaryTemplateID),
            "summary_template_name": Self.optionalTextValue(snapshot.summaryTemplateName),
            "summary_template_user_edition": Self.optionalTextValue(snapshot.summaryTemplateUserEdition),
            "session_tag": Self.optionalTextValue(snapshot.sessionTag),
        ]
        return try await request(
            url: VoxellaAPIConfiguration.sessionURL(snapshot.remoteSessionID)
                .appending(path: "desktop-sync"),
            method: "PUT",
            json: body,
            as: VoxellaDesktopSessionSyncResponse.self
        )
    }

    func confirmEphemeralCompletion(sessionID: UUID) async throws {
        struct Empty: Decodable {}
        _ = try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "ephemeral-complete"),
            method: "POST",
            json: [:] as [String: Any],
            as: Empty.self
        )
    }

    func cancelSession(_ sessionID: UUID) async throws {
        try await cancelSession(sessionID, preserveSession: false)
    }

    func cancelSession(_ sessionID: UUID, preserveSession: Bool) async throws {
        struct Empty: Decodable {}
        _ = try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "cancel"),
            method: "POST",
            json: ["preserve_session": preserveSession],
            as: Empty.self
        )
    }

    func deleteSession(_ sessionID: UUID) async throws {
        struct Empty: Decodable {}
        _ = try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID),
            method: "DELETE",
            as: Empty.self
        )
    }

    func regenerateTranscript(
        sessionID: UUID,
        options: TranscriptionProcessingOptions
    ) async throws -> VoxellaUploadCompleteResponse {
        try await request(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "regenerate-transcript"),
            method: "POST",
            json: regenerateOptions(options),
            as: VoxellaUploadCompleteResponse.self
        )
    }

    func putData(
        _ data: Data,
        to url: URL,
        method: String? = nil,
        headers: [String: String]? = nil,
        contentType: String? = nil
    ) async throws -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = method ?? "PUT"
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw VoxellaAPIError.http(code, "Upload failed.")
        }
        return http.value(forHTTPHeaderField: "ETag")
    }

    func putFile(
        _ fileURL: URL,
        to url: URL,
        method: String? = nil,
        headers: [String: String]? = nil,
        contentType: String? = nil
    ) async throws -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = method ?? "PUT"
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw VoxellaAPIError.http(code, "Upload failed.")
        }
        return http.value(forHTTPHeaderField: "ETag")
    }

    func events(
        sessionID: UUID,
        runStartedAt: Date? = nil
    ) -> AsyncThrowingStream<VoxellaSSEEvent, Error> {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "events"),
            resolvingAgainstBaseURL: false
        )!
        if let runStartedAt {
            components.queryItems = [
                URLQueryItem(
                    name: "run_started_ms",
                    value: String(Int(runStartedAt.timeIntervalSince1970 * 1_000))
                ),
            ]
        }
        let url = components.url ?? VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: "events")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.consumeSSEWithReconnect(
                        url: url,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consumeSSEWithReconnect(
        url: URL,
        continuation: AsyncThrowingStream<VoxellaSSEEvent, Error>.Continuation
    ) async throws {
        var reconnectAttempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await consumeSSE(
                    url: url,
                    continuation: continuation,
                    retryingUnauthorized: true
                )
                reconnectAttempt = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch VoxellaAPIError.cancelled {
                throw VoxellaAPIError.cancelled
            } catch {
                reconnectAttempt += 1
                if reconnectAttempt > 6 { throw error }
            }
            let delay = min(30, 1 << min(reconnectAttempt, 5))
            try await Task.sleep(for: .seconds(Double(delay)))
        }
    }

    private func consumeSSE(
        url: URL,
        continuation: AsyncThrowingStream<VoxellaSSEEvent, Error>.Continuation,
        retryingUnauthorized: Bool
    ) async throws {
        var request = try await authorizedRequest(url: url, method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 0
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoxellaAPIError.http(0, "No response")
        }
        if http.statusCode == 401 {
            if retryingUnauthorized {
                _ = try await auth.refreshAccessToken()
                try await consumeSSE(url: url, continuation: continuation, retryingUnauthorized: false)
                return
            }
            throw VoxellaAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VoxellaAPIError.http(http.statusCode, "Could not subscribe to VoxStudio progress.")
        }
        var buffer = ""
        for try await line in bytes.lines {
            if Task.isCancelled { throw VoxellaAPIError.cancelled }
            if line.isEmpty {
                if let event = VoxellaSSEEvent.parse(buffer) {
                    continuation.yield(event)
                }
                buffer = ""
            } else {
                buffer += line + "\n"
            }
        }
    }

    private func sessionOptions(
        _ options: TranscriptionProcessingOptions,
        placement: TranscriptionPlacement,
        mimeType: String,
        filename: String,
        durationSec: Double? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "persistence_scope": TranscriptionPlacementRouter.remotePersistenceScope(placement)?.rawValue
                ?? RemotePersistenceScope.persistent.rawValue,
            "client_compute": TranscriptionPlacementRouter.remoteClientCompute(placement)?.rawValue
                ?? RemoteClientCompute.cloud.rawValue,
        ]
        payload.merge(sessionMediaOptions(mimeType: mimeType, filename: filename)) { _, new in new }
        if let durationSec, durationSec.isFinite, durationSec > 0 {
            payload["duration_ms"] = max(1, Int((durationSec * 1000).rounded()))
        }
        if let language = options.languageCode { payload["language_hint"] = language }
        if let target = options.normalizedTargetLanguageCode { payload["target_language"] = target }
        if let speakers = options.speakerCount.count {
            payload["min_speakers"] = speakers
            payload["max_speakers"] = speakers
            payload["speaker_diarization"] = "force"
        } else {
            payload["speaker_diarization"] = "auto"
        }
        if let start = options.clipStartMs { payload["clip_start_ms"] = start }
        if let end = options.clipEndMs { payload["clip_end_ms"] = end }
        return payload
    }

    private func regenerateOptions(_ options: TranscriptionProcessingOptions) -> [String: Any] {
        var payload: [String: Any] = [:]
        payload["target_language"] = options.normalizedTargetLanguageCode ?? NSNull()
        if let language = options.languageCode { payload["language_hint"] = language }
        if let speakers = options.speakerCount.count {
            payload["min_speakers"] = speakers
            payload["max_speakers"] = speakers
        }
        if let start = options.clipStartMs { payload["clip_start_ms"] = start }
        if let end = options.clipEndMs { payload["clip_end_ms"] = end }
        return payload
    }

    private func summaryGenerationBody(
        templateID: String?,
        templateUpdate: VoxellaSummaryTemplateUpdatePayload?
    ) -> [String: Any] {
        var body: [String: Any] = [:]
        if let templateID, !templateID.isEmpty {
            body["template_id"] = templateID
        }
        if let templateUpdate {
            body["template_update"] = templateUpdate.jsonObject()
        }
        return body
    }

    private func sessionMediaOptions(mimeType: String, filename: String) -> [String: Any] {
        guard Self.containsVideo(mimeType: mimeType, filename: filename) else { return [:] }
        return ["upload_has_video": true]
    }

    nonisolated static func containsVideo(mimeType: String, filename: String) -> Bool {
        let mime = mimeType.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        if mime.hasPrefix("video/") { return true }
        return ClipType(fileExtension: URL(fileURLWithPath: filename).pathExtension.lowercased()) == .video
    }

    private func request<T: Decodable>(
        url: URL,
        method: String,
        json: [String: Any]? = nil,
        as type: T.Type
    ) async throws -> T {
        do {
            return try await send(url: url, method: method, json: json, as: type, retryingUnauthorized: true)
        } catch VoxellaAPIError.unauthorized {
            throw VoxellaAPIError.unauthorized
        }
    }

    private func send<T: Decodable>(
        url: URL,
        method: String,
        json: [String: Any]?,
        as type: T.Type,
        retryingUnauthorized: Bool
    ) async throws -> T {
        var request = try await authorizedRequest(url: url, method: method)
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoxellaAPIError.http(0, "No response")
        }
        if http.statusCode == 401, retryingUnauthorized {
            _ = try await auth.refreshAccessToken()
            return try await send(url: url, method: method, json: json, as: type, retryingUnauthorized: false)
        }
        if http.statusCode == 401 {
            throw VoxellaAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw VoxellaAPIError.http(http.statusCode, message)
        }
        if data.isEmpty {
            do {
                return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
            } catch {
                throw VoxellaAPIError.decoding
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VoxellaAPIError.decoding
        }
    }

    private func authorizedRequest(url: URL, method: String) async throws -> URLRequest {
        let token = try await auth.authorizedAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func sendMultipart<T: Decodable>(
        url: URL,
        fields: [String: String],
        fileData: Data,
        filename: String,
        contentType: String,
        as type: T.Type,
        retryingUnauthorized: Bool = true
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = try await authorizedRequest(url: url, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoxellaAPIError.http(0, "No response")
        }
        if http.statusCode == 401, retryingUnauthorized {
            _ = try await auth.refreshAccessToken()
            return try await sendMultipart(
                url: url,
                fields: fields,
                fileData: fileData,
                filename: filename,
                contentType: contentType,
                as: type,
                retryingUnauthorized: false
            )
        }
        if http.statusCode == 401 { throw VoxellaAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw VoxellaAPIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VoxellaAPIError.decoding
        }
    }

    private func sessionListURL(
        _ sessionID: UUID,
        path: String,
        cursor: String?,
        limit: Int
    ) -> URL {
        var components = URLComponents(
            url: VoxellaAPIConfiguration.sessionURL(sessionID).appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        return components.url!
    }

    private static func encodeSegment(_ segment: TranscriptionSegment) -> [String: Any] {
        [
            "start": segment.start,
            "end": segment.end,
            "text": segment.text,
            "speaker": segment.speaker ?? NSNull(),
        ]
    }

    private static func encodeWord(_ word: TranscriptionWord) -> [String: Any] {
        [
            "word": word.text,
            "start": word.start ?? NSNull(),
            "end": word.end ?? NSNull(),
            "speaker": word.speaker ?? NSNull(),
        ]
    }

    private static func encodeCue(_ cue: SubtitleCue) -> [String: Any] {
        [
            "start": cue.start,
            "end": cue.end,
            "text": cue.text,
            "speaker": cue.speaker ?? NSNull(),
        ]
    }

    private static func optionalTextValue(_ value: String?) -> Any {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? NSNull() : normalized
    }

    private static func encodeDubSegment(_ segment: DubSegmentPayload) -> [String: Any] {
        var payload: [String: Any] = [
            "index": segment.index,
            "text": segment.text,
        ]
        if let start = segment.start { payload["start_s"] = start }
        if let end = segment.end { payload["end_s"] = end }
        if let speaker = segment.speaker { payload["speaker_label"] = speaker }
        if let sourceID = segment.sourceSubtitleID { payload["source_subtitle_id"] = sourceID }
        payload.merge(segment.options) { _, new in new }
        return payload
    }

    private static func encodeDubRenderedSegment(_ segment: DubRenderedSegment) -> [String: Any] {
        var payload: [String: Any] = [
            "index": segment.index,
            "text": segment.text,
            "start_s": segment.start,
            "end_s": segment.end,
        ]
        if let speaker = segment.speaker { payload["speaker_label"] = speaker }
        if let sourceID = segment.sourceSubtitleID { payload["source_subtitle_id"] = sourceID }
        return payload
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
}

struct VoxellaSSEEvent: Sendable {
    var event: String
    var data: [String: VoxellaJSONValue]

    var eventName: String { data["event"]?.stringValue ?? event }
    var stage: String? { data["stage"]?.stringValue ?? data["current_stage"]?.stringValue }
    var status: String? { data["status"]?.stringValue }
    var resultReady: Bool? { data["result_ready"]?.boolValue }
    var message: String? { data["message"]?.stringValue ?? data["detail"]?.stringValue }
    var failureMode: String? { data["failure_mode"]?.stringValue }
    var failureReason: String? { data["failure_reason"]?.stringValue }
    var workflowRunID: String? {
        data["workflow_run_id"]?.stringValue ?? data["transcribe_run_id"]?.stringValue
    }
    var generationID: String? { data["generation_id"]?.stringValue }
    var progress: Double? { data["progress"]?.numberValue }
    var step: String? { data["step"]?.stringValue }
    var stageProgress: Double? { data["stage_progress"]?.numberValue }
    var scriptIndex: Int? { integerValue(for: "script_index") }
    var scriptTotal: Int? { integerValue(for: "script_total") }
    var elapsedSeconds: Double? { data["elapsed_seconds"]?.numberValue }
    var producer: String? { data["producer"]?.stringValue }
    var commitPhase: String? { data["commit_phase"]?.stringValue }
    var isSnapshot: Bool { data["is_snapshot"]?.boolValue ?? false }
    var chunkIndex: Int? { integerValue(for: "chunk_index") }
    var completedChunks: Int? { integerValue(for: "completed_chunks") }
    var totalChunks: Int? { integerValue(for: "total_chunks") ?? integerValue(for: "chunk_count") }
    var balance: Double? { data["balance"]?.numberValue ?? data["balance_snapshot"]?.numberValue }
    var timestampMilliseconds: Int? { integerValue(for: "ts_ms") }

    var isInternalConnectionEvent: Bool {
        ["sse_connected", "balance_update"].contains(eventName.lowercased())
    }

    var isFailOpenDiarizationDegradation: Bool {
        let normalizedStage = stage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMode = failureMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedStage == "diarization"
            && normalizedMode == "fail_open"
            && eventName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "diarization_degraded"
    }

    private func integerValue(for key: String) -> Int? {
        guard let value = data[key]?.numberValue,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max)
        else {
            return nil
        }
        return Int(value)
    }

    static func parse(_ raw: String) -> VoxellaSSEEvent? {
        var eventName = "message"
        var dataLines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
        }
        let payload = dataLines.joined()
        guard let data = payload.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: VoxellaJSONValue].self, from: data)
        else {
            return VoxellaSSEEvent(event: eventName, data: [:])
        }
        return VoxellaSSEEvent(event: eventName, data: object)
    }
}
