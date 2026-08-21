import Foundation

/// Summary template definitions for local Studio postprocess.
/// Auto-summary uses a general adaptive template until the user applies a catalog template.

struct SummaryTemplateDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var userEdition: String
    var isFallback: Bool
    var categoryCode: String?
    var scope: String
    var sourceTemplateID: String?
    var emojiIcon: String?

    var isPrivate: Bool { scope == "private" }

    /// Catalog `is_fallback` Interview Notes id — kept for remote template identity only.
    static let interviewNotesFallbackID = "66666666-6666-6666-6666-666666666666"

    /// Local default: content-agnostic adaptive summary.
    static let generalSummaryID = "local-general-summary-v1"

    static let generalSummary = SummaryTemplateDefinition(
        id: generalSummaryID,
        name: "General Summary",
        description: "Adaptive summary for any session. Surfaces the points users care about most.",
        userEdition: """
        ## Role Description
        You are a general-purpose session summarizer. Stay faithful to the transcript. Do not fabricate facts, names, numbers, or decisions. Output strict markdown only.

        ## Adaptive goal
        Infer the content type (meeting, interview, lecture, promo/ad, support call, technical discussion, media commentary, casual notes, or mixed) from the transcript itself. Then produce the most useful summary for that type — maximize signal, minimize boilerplate.

        ## Output rules
        1) Write in the source language of the transcript (or the user's preferred language if clearly implied).
        2) Use markdown headings (`##`) only for user-facing sections you include.
        3) Do NOT output role/persona/meta instructions.
        4) Prefer concrete facts, claims, offers, numbers, names, dates, and commitments over vague adjectives.
        5) Include short evidence quotes only when they materially support a key point.
        6) Omit any section that would be empty or speculative — omit the heading too. Never leave a heading with a blank body.
        7) Keep the summary compact but information-dense.
        8) Key Points are takeaways only. Put the concrete record in Details & Facts instead of dropping it.

        ## Sections
        - **Overview** (required, short paragraph): What this session is about and why it matters.
        - **Key Points** (required, bullets): The highest-value takeaways a busy reader would want first. Keep this short.
        - **Details & Facts** (required whenever unused specifics remain): People, organizations, dates, places, numbers, products, offers, constraints, and evidence. Interviews, lectures, and long sessions must include this.
        - **Decisions & Actions** (optional, bullets): Explicit decisions, commitments, next steps, owners/due dates if stated.
        - **Notable Quotes** (optional, bullets): A few high-signal lines with brief context.
        - **Open Questions / Risks** (optional, bullets): Unresolved questions, risks, or follow-ups implied by the source.

        Choose optional sections dynamically so a meeting, a class lecture, and a short promo each feel correctly summarized — not forced into an interview template. Always finish required sections that have source support.
        """,
        isFallback: true,
        categoryCode: "general",
        scope: "local",
        sourceTemplateID: nil,
        emojiIcon: "📝"
    )

    /// Local Studio fallback when the user is signed out or the catalog is unavailable.
    static var locallySupported: [SummaryTemplateDefinition] {
        [generalSummary]
    }
}

struct SummaryTemplateTree: Sendable, Equatable {
    struct Category: Identifiable, Sendable, Equatable {
        var id: String { code }
        var code: String
        var name: String
        var children: [Subcategory]
    }

    struct Subcategory: Identifiable, Sendable, Equatable {
        var id: String { code }
        var code: String
        var name: String
        var templates: [SummaryTemplateDefinition]
    }

    var locale: String
    var categories: [Category]
    var templates: [SummaryTemplateDefinition]

    func template(id: String?) -> SummaryTemplateDefinition? {
        guard let id, !id.isEmpty else { return nil }
        return templates.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func privateCopy(ofPublicTemplateID publicID: String) -> SummaryTemplateDefinition? {
        templates.first {
            $0.isPrivate
                && $0.sourceTemplateID?.caseInsensitiveCompare(publicID) == .orderedSame
        }
    }
}

enum SummaryTemplateCatalogError: LocalizedError {
    case signInRequired
    case networkUnavailable
    case emptyCatalog
    case decodeFailed
    case templateNotFound
    case prepareFailed

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in at voxstudio.me to use custom summary templates."
        case .networkUnavailable:
            return "Network is unavailable. Connect to load summary templates."
        case .emptyCatalog:
            return "No summary templates were returned."
        case .decodeFailed:
            return "Could not read the summary template catalog."
        case .templateNotFound:
            return "The selected summary template could not be loaded."
        case .prepareFailed:
            return "Failed to prepare the summary template."
        }
    }
}

enum SummaryTemplateLocale {
    static let supported = ["en", "de", "nl", "pl", "zh-CN", "ja", "zh-TW", "es", "it"]

    static func resolve(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if supported.contains(value) { return value }

        let lowered = value.lowercased().replacingOccurrences(of: "_", with: "-")
        if lowered.isEmpty { return "en" }
        if ["zh-tw", "zh-hk", "zh-mo", "zh-hant"].contains(lowered) { return "zh-TW" }
        if ["zh-cn", "zh-sg", "zh-my", "zh-hans"].contains(lowered) { return "zh-CN" }
        if supported.contains(where: { $0.lowercased() == lowered }) {
            return supported.first { $0.lowercased() == lowered } ?? "en"
        }
        let primary = lowered.split(separator: "-", maxSplits: 1).first.map(String.init) ?? lowered
        if let match = supported.first(where: { $0.lowercased() == primary }) {
            return match
        }
        return "en"
    }
}

actor SummaryTemplateCatalog {
    static let shared = SummaryTemplateCatalog()

    private let client: VoxellaAPIClient
    private var cachedTree: SummaryTemplateTree?
    private var cachedAt: Date?
    private var templatesByID: [String: SummaryTemplateDefinition] = [:]

    init(client: VoxellaAPIClient = .shared) {
        self.client = client
    }

    func locallySupportedTemplate() -> SummaryTemplateDefinition {
        .generalSummary
    }

    func template(forID id: String?) -> SummaryTemplateDefinition {
        guard let id, !id.isEmpty else { return .generalSummary }
        if let local = SummaryTemplateDefinition.locallySupported.first(where: { $0.id == id }) {
            return local
        }
        if let remembered = templatesByID[id.lowercased()] {
            return remembered
        }
        if let cached = cachedTree?.template(id: id) {
            return cached
        }
        return .generalSummary
    }

    func template(
        forID id: String?,
        name: String?,
        userEdition: String?
    ) -> SummaryTemplateDefinition {
        var template = template(forID: id)
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { template.name = trimmed }
        }
        if let userEdition {
            let trimmed = userEdition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { template.userEdition = trimmed }
        }
        return template
    }

    func fetchTree(
        locale: String,
        forceRefresh: Bool = false
    ) async throws -> SummaryTemplateTree {
        if !forceRefresh,
           let cachedTree,
           let cachedAt,
           Date().timeIntervalSince(cachedAt) < 60 {
            return cachedTree
        }
        do {
            let remote = try await client.summaryTemplateTree(
                scope: "all",
                locale: SummaryTemplateLocale.resolve(locale)
            )
            let tree = Self.decodeTree(remote)
            guard !tree.templates.isEmpty else { throw SummaryTemplateCatalogError.emptyCatalog }
            cachedTree = tree
            cachedAt = Date()
            for template in tree.templates {
                remember(template, overwriteEdition: false)
            }
            return tree
        } catch let error as SummaryTemplateCatalogError {
            throw error
        } catch VoxellaAPIError.unauthorized {
            throw SummaryTemplateCatalogError.signInRequired
        } catch VoxellaAPIError.decoding {
            throw SummaryTemplateCatalogError.decodeFailed
        } catch {
            throw SummaryTemplateCatalogError.networkUnavailable
        }
    }

    func loadTemplate(id: String, locale: String) async throws -> SummaryTemplateDefinition {
        do {
            let remote = try await client.summaryTemplate(
                id: id,
                locale: SummaryTemplateLocale.resolve(locale)
            )
            let template = Self.definition(from: remote)
            remember(template, overwriteEdition: true)
            return template
        } catch let error as SummaryTemplateCatalogError {
            throw error
        } catch VoxellaAPIError.unauthorized {
            throw SummaryTemplateCatalogError.signInRequired
        } catch VoxellaAPIError.http(404, _) {
            throw SummaryTemplateCatalogError.templateNotFound
        } catch VoxellaAPIError.decoding {
            throw SummaryTemplateCatalogError.decodeFailed
        } catch {
            throw SummaryTemplateCatalogError.networkUnavailable
        }
    }

    func assistEdit(
        templateID: String,
        instruction: String,
        currentUserEdition: String
    ) async throws -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        do {
            let response = try await client.assistSummaryTemplate(
                id: templateID,
                instruction: trimmed,
                currentUserEdition: currentUserEdition
            )
            return response.candidateUserEdition.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch VoxellaAPIError.unauthorized {
            throw SummaryTemplateCatalogError.signInRequired
        } catch {
            throw SummaryTemplateCatalogError.networkUnavailable
        }
    }

    /// Copies a public template to a private user edition, then patches any draft changes.
    func persistDraft(
        templateID: String,
        name: String,
        description: String,
        userEdition: String
    ) async throws -> SummaryTemplateDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEdition = userEdition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedEdition.isEmpty else {
            throw SummaryTemplateCatalogError.prepareFailed
        }

        let copied: VoxellaSummaryTemplate
        do {
            copied = try await client.copySummaryTemplateForEdit(id: templateID, reuseExisting: true)
        } catch VoxellaAPIError.unauthorized {
            throw SummaryTemplateCatalogError.signInRequired
        } catch {
            throw SummaryTemplateCatalogError.prepareFailed
        }

        let copiedDefinition = Self.definition(from: copied)
        var nameUpdate: String?
        var descriptionUpdate: String?
        var editionUpdate: String?
        if trimmedName != copiedDefinition.name { nameUpdate = trimmedName }
        if !trimmedDescription.isEmpty, trimmedDescription != copiedDefinition.description {
            descriptionUpdate = trimmedDescription
        }
        if trimmedEdition != copiedDefinition.userEdition { editionUpdate = trimmedEdition }

        var resolved = copiedDefinition
        if nameUpdate != nil || descriptionUpdate != nil || editionUpdate != nil {
            do {
                let updated = try await client.updateSummaryTemplate(
                    id: copiedDefinition.id,
                    name: nameUpdate,
                    description: descriptionUpdate,
                    userEdition: editionUpdate
                )
                resolved = Self.definition(from: updated.template)
            } catch VoxellaAPIError.unauthorized {
                throw SummaryTemplateCatalogError.signInRequired
            } catch {
                throw SummaryTemplateCatalogError.prepareFailed
            }
        }

        resolved.name = trimmedName
        resolved.description = trimmedDescription.isEmpty ? resolved.description : trimmedDescription
        resolved.userEdition = trimmedEdition
        remember(resolved, overwriteEdition: true)
        cachedTree = nil
        cachedAt = nil
        return resolved
    }

    private func remember(_ template: SummaryTemplateDefinition, overwriteEdition: Bool) {
        let key = template.id.lowercased()
        if !overwriteEdition, let existing = templatesByID[key], !existing.userEdition.isEmpty {
            var merged = template
            if template.userEdition.isEmpty {
                merged.userEdition = existing.userEdition
            }
            templatesByID[key] = merged
            return
        }
        templatesByID[key] = template
    }

    private static func decodeTree(_ remote: VoxellaSummaryTemplateTreeResponse) -> SummaryTemplateTree {
        let categories = remote.categories.map { category in
            SummaryTemplateTree.Category(
                code: category.code,
                name: category.name,
                children: category.children.map { subcategory in
                    var templates = subcategory.templates.map { definition(from: $0, categoryCode: category.code) }
                    templates.sort(by: preferredOrder)
                    return SummaryTemplateTree.Subcategory(
                        code: subcategory.code,
                        name: subcategory.name,
                        templates: templates
                    )
                }
            )
        }
        var flat: [SummaryTemplateDefinition] = []
        for category in categories {
            for subcategory in category.children {
                flat.append(contentsOf: subcategory.templates)
            }
        }
        for template in remote.templates.map({ definition(from: $0) }) where !flat.contains(where: { $0.id == template.id }) {
            flat.append(template)
        }
        flat.sort(by: preferredOrder)
        return SummaryTemplateTree(locale: remote.locale, categories: categories, templates: flat)
    }

    private static func preferredOrder(lhs: SummaryTemplateDefinition, rhs: SummaryTemplateDefinition) -> Bool {
        if lhs.isPrivate != rhs.isPrivate { return lhs.isPrivate }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func definition(
        from remote: VoxellaSummaryTemplate,
        categoryCode: String? = nil
    ) -> SummaryTemplateDefinition {
        let edition = (remote.userEdition ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return SummaryTemplateDefinition(
            id: remote.id,
            name: remote.name,
            description: remote.description,
            userEdition: edition,
            isFallback: remote.isFallback,
            categoryCode: categoryCode,
            scope: remote.scope,
            sourceTemplateID: remote.sourceTemplateID,
            emojiIcon: remote.emojiIcon
        )
    }
}
