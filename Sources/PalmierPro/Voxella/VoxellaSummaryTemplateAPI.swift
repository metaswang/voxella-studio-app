import Foundation

struct VoxellaSummaryTemplate: Decodable, Sendable {
    var id: String
    var scope: String
    var ownerUserID: String?
    var name: String
    var description: String
    var emojiIcon: String?
    var userEdition: String?
    var languageMode: String?
    var isFallback: Bool
    var isActive: Bool
    var version: Int?
    var categoryID: String?
    var categoryName: String?
    var sourceTemplateID: String?
    var editable: Bool
    var isCopiedFromPublic: Bool

    enum CodingKeys: String, CodingKey {
        case id, scope, name, description, version, editable
        case ownerUserID = "owner_user_id"
        case emojiIcon = "emoji_icon"
        case userEdition = "user_edition"
        case languageMode = "language_mode"
        case isFallback = "is_fallback"
        case isActive = "is_active"
        case categoryID = "category_id"
        case categoryName = "category_name"
        case sourceTemplateID = "source_template_id"
        case isCopiedFromPublic = "is_copied_from_public"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeID(container, forKey: .id)
        scope = (try container.decodeIfPresent(String.self, forKey: .scope) ?? "public")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if scope.isEmpty { scope = "public" }
        ownerUserID = try Self.decodeOptionalID(container, forKey: .ownerUserID)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? "Template")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Template" }
        description = (try container.decodeIfPresent(String.self, forKey: .description) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        emojiIcon = try container.decodeIfPresent(String.self, forKey: .emojiIcon)
        userEdition = try container.decodeIfPresent(String.self, forKey: .userEdition)
        languageMode = try container.decodeIfPresent(String.self, forKey: .languageMode)
        isFallback = try container.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        categoryID = try Self.decodeOptionalID(container, forKey: .categoryID)
        categoryName = try container.decodeIfPresent(String.self, forKey: .categoryName)
        sourceTemplateID = try Self.decodeOptionalID(container, forKey: .sourceTemplateID)
        editable = try container.decodeIfPresent(Bool.self, forKey: .editable) ?? true
        isCopiedFromPublic = try container.decodeIfPresent(Bool.self, forKey: .isCopiedFromPublic)
            ?? (scope == "private" && sourceTemplateID != nil)
    }

    private static func decodeID(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String {
        if let value = try decodeOptionalID(container, forKey: key), !value.isEmpty {
            return value
        }
        throw DecodingError.keyNotFound(
            key,
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing template id")
        )
    }

    private static func decodeOptionalID(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let uuid = try container.decodeIfPresent(UUID.self, forKey: key) {
            return uuid.uuidString.lowercased()
        }
        return nil
    }
}

struct VoxellaSummaryTemplateTreeSubcategory: Decodable, Sendable {
    var id: String?
    var code: String
    var name: String
    var sortOrder: Int
    var templates: [VoxellaSummaryTemplate]

    enum CodingKeys: String, CodingKey {
        case id, code, name, templates
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(UUID.self, forKey: .id).map { $0.uuidString.lowercased() }
        code = (try container.decodeIfPresent(String.self, forKey: .code) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? code)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 100
        templates = try container.decodeIfPresent([VoxellaSummaryTemplate].self, forKey: .templates) ?? []
    }
}

struct VoxellaSummaryTemplateTreeCategory: Decodable, Sendable {
    var id: String?
    var code: String
    var name: String
    var sortOrder: Int
    var children: [VoxellaSummaryTemplateTreeSubcategory]

    enum CodingKeys: String, CodingKey {
        case id, code, name, children
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(UUID.self, forKey: .id).map { $0.uuidString.lowercased() }
        code = (try container.decodeIfPresent(String.self, forKey: .code) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = (try container.decodeIfPresent(String.self, forKey: .name) ?? code)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 100
        children = try container.decodeIfPresent(
            [VoxellaSummaryTemplateTreeSubcategory].self,
            forKey: .children
        ) ?? []
    }
}

struct VoxellaSummaryTemplateTreeResponse: Decodable, Sendable {
    var locale: String
    var categories: [VoxellaSummaryTemplateTreeCategory]
    var templates: [VoxellaSummaryTemplate]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? "en"
        categories = try container.decodeIfPresent(
            [VoxellaSummaryTemplateTreeCategory].self,
            forKey: .categories
        ) ?? []
        templates = try container.decodeIfPresent([VoxellaSummaryTemplate].self, forKey: .templates) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case locale, categories, templates
    }
}

struct VoxellaSummaryTemplateUpdateResponse: Decodable, Sendable {
    var template: VoxellaSummaryTemplate
}

struct VoxellaSummaryTemplateAiEditResponse: Decodable, Sendable {
    var candidateUserEdition: String

    enum CodingKeys: String, CodingKey {
        case candidateUserEdition = "candidate_user_edition"
    }
}

struct VoxellaSummaryTemplateUpdatePayload: Sendable, Equatable {
    var name: String?
    var description: String?
    var userEdition: String?
    var autoExtractSchema = true

    func jsonObject() -> [String: Any] {
        var body: [String: Any] = ["auto_extract_schema": autoExtractSchema]
        if let name, !name.isEmpty { body["name"] = name }
        if let description, !description.isEmpty { body["description"] = description }
        if let userEdition, !userEdition.isEmpty { body["user_edition"] = userEdition }
        return body
    }
}

struct VoxellaSummaryEnqueueResponse: Decodable, Sendable {
    var jobID: String
    var templateID: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case templateID = "template_id"
    }
}

struct VoxellaSessionTag: Decodable, Sendable {
    var id: String?
    var tagText: String
    var confidence: Double?
    var source: String

    enum CodingKeys: String, CodingKey {
        case id
        case tagText = "tag_text"
        case confidence
        case source
    }
}

struct VoxellaSessionSummaryRun: Decodable, Sendable {
    var id: String
    var sessionID: String
    var templateID: String?
    var triggerSource: String
    var routerReason: String?
    var routerScore: Double?
    var outputMarkdown: String
    var status: String
    var errorMessage: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case templateID = "template_id"
        case triggerSource = "trigger_source"
        case routerReason = "router_reason"
        case routerScore = "router_score"
        case outputMarkdown = "output_markdown"
        case status
        case errorMessage = "error_message"
        case createdAt = "created_at"
    }
}

struct VoxellaSessionSummaryResponse: Decodable, Sendable {
    var summary: VoxellaSessionSummaryRun?
    var template: VoxellaSummaryTemplate?
    var tag: VoxellaSessionTag?
    var recommendedTemplateIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case summary
        case template
        case tag
        case recommendedTemplateIDs = "recommended_template_ids"
    }
}

struct VoxellaSessionSummaryUpdateResponse: Decodable, Sendable {
    var summary: VoxellaSessionSummaryRun
}
