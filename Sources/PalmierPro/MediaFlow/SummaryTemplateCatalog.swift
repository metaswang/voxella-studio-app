import Foundation

/// Summary template definitions aligned with voxella-api `summary_templates` seed catalog.
/// Local Studio currently supports only the public fallback template (Interview Notes).

struct SummaryTemplateDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var userEdition: String
    var isFallback: Bool
    var categoryCode: String?

    /// Global `is_fallback` template from `20260223_seed_summary_templates_catalog_v1.sql`.
    static let interviewNotesFallbackID = "66666666-6666-6666-6666-666666666666"

    static let interviewNotes = SummaryTemplateDefinition(
        id: interviewNotesFallbackID,
        name: "Interview Notes",
        description: "For user/research interviews. Focus on insights with evidence.",
        userEdition: """
        ## Role Description
        You are an interview-insights assistant. Stay faithful to the source and do not fabricate facts. Output strict markdown only.

        ## Output Items (required/optional, type)
        - **Respondent Profile** (optional, paragraph): Brief context about the respondent.
        - **Key Insights** (required, bullet list): Main insights from the interview.
        - **Evidence Quotes** (required, bullet list): Direct quotes from the transcript that support the insights.
        - **Opportunities** (required, bullet list): Opportunity areas or follow-up actions.
        """,
        isFallback: true,
        categoryCode: "research.interview"
    )

    /// Local Studio temporarily supports only the catalog fallback template.
    static var locallySupported: [SummaryTemplateDefinition] {
        [interviewNotes]
    }
}

enum SummaryTemplateCatalogError: LocalizedError {
    case signInRequired
    case networkUnavailable
    case emptyCatalog
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in and connect to the network to load summary templates."
        case .networkUnavailable:
            return "Network is unavailable. Connect to load summary templates."
        case .emptyCatalog:
            return "No summary templates were returned."
        case .decodeFailed:
            return "Could not read the summary template catalog."
        }
    }
}

actor SummaryTemplateCatalog {
    static let shared = SummaryTemplateCatalog()

    /// Production API host from voxella-docker-deploy `.env.prod.myvps2` (`INTERNAL_API__BASE_URL`).
    static let productionAPIBaseURL = URL(string: "https://voxstudio.me")!

    private var cachedRemote: [SummaryTemplateDefinition]?
    private var cachedAt: Date?

    func locallySupportedTemplate() -> SummaryTemplateDefinition {
        .interviewNotes
    }

    /// Requires network. When authenticated, prefer the remote fallback template; otherwise fail with sign-in guidance.
    func fetchSupportedTemplates(
        isSignedIn: Bool,
        authToken: String?
    ) async throws -> [SummaryTemplateDefinition] {
        guard isSignedIn else { throw SummaryTemplateCatalogError.signInRequired }
        if let cachedRemote, let cachedAt, Date().timeIntervalSince(cachedAt) < 3600 {
            return filterLocallySupported(cachedRemote)
        }

        do {
            let remote = try await fetchRemoteTree(authToken: authToken)
            cachedRemote = remote
            cachedAt = Date()
            let filtered = filterLocallySupported(remote)
            return filtered.isEmpty ? SummaryTemplateDefinition.locallySupported : filtered
        } catch SummaryTemplateCatalogError.signInRequired {
            throw SummaryTemplateCatalogError.signInRequired
        } catch {
            // Remote catalog is preferred when online, but the seeded fallback
            // remains usable so every completed local session can still summarize.
            Log.project.warning(
                "summary template fetch failed: \(error.localizedDescription); using bundled fallback"
            )
            return SummaryTemplateDefinition.locallySupported
        }
    }

    private func filterLocallySupported(
        _ templates: [SummaryTemplateDefinition]
    ) -> [SummaryTemplateDefinition] {
        let allowed = Set(SummaryTemplateDefinition.locallySupported.map(\.id))
        let matched = templates.filter { allowed.contains($0.id) || $0.isFallback }
        if let fallback = matched.first(where: { $0.id == SummaryTemplateDefinition.interviewNotesFallbackID })
            ?? matched.first(where: \.isFallback) {
            return [fallback]
        }
        return SummaryTemplateDefinition.locallySupported
    }

    private func fetchRemoteTree(authToken: String?) async throws -> [SummaryTemplateDefinition] {
        var components = URLComponents(
            url: Self.productionAPIBaseURL.appendingPathComponent("api/v1/summary-templates/tree"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "locale", value: "en")]
        guard let url = components.url else { throw SummaryTemplateCatalogError.networkUnavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        } else {
            throw SummaryTemplateCatalogError.signInRequired
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SummaryTemplateCatalogError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw SummaryTemplateCatalogError.networkUnavailable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SummaryTemplateCatalogError.signInRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SummaryTemplateCatalogError.networkUnavailable
        }

        return try decodeTree(data)
    }

    private func decodeTree(_ data: Data) throws -> [SummaryTemplateDefinition] {
        struct TreeResponse: Decodable {
            struct Node: Decodable {
                let templates: [RemoteTemplate]?
                let children: [Node]?
            }
            struct RemoteTemplate: Decodable {
                let id: String
                let name: String?
                let description: String?
                let userEdition: String?
                let isFallback: Bool?
                let categoryCode: String?

                enum CodingKeys: String, CodingKey {
                    case id, name, description
                    case userEdition = "user_edition"
                    case isFallback = "is_fallback"
                    case categoryCode = "category_code"
                }
            }

            let categories: [Node]?
            let templates: [RemoteTemplate]?
        }

        let decoded: TreeResponse
        do {
            decoded = try JSONDecoder().decode(TreeResponse.self, from: data)
        } catch {
            throw SummaryTemplateCatalogError.decodeFailed
        }

        var collected: [SummaryTemplateDefinition] = []
        func walk(_ nodes: [TreeResponse.Node]?) {
            guard let nodes else { return }
            for node in nodes {
                for template in node.templates ?? [] {
                    collected.append(
                        SummaryTemplateDefinition(
                            id: template.id,
                            name: template.name ?? "Template",
                            description: template.description ?? "",
                            userEdition: template.userEdition
                                ?? SummaryTemplateDefinition.interviewNotes.userEdition,
                            isFallback: template.isFallback ?? false,
                            categoryCode: template.categoryCode
                        )
                    )
                }
                walk(node.children)
            }
        }
        walk(decoded.categories)
        for template in decoded.templates ?? [] {
            collected.append(
                SummaryTemplateDefinition(
                    id: template.id,
                    name: template.name ?? "Template",
                    description: template.description ?? "",
                    userEdition: template.userEdition
                        ?? SummaryTemplateDefinition.interviewNotes.userEdition,
                    isFallback: template.isFallback ?? false,
                    categoryCode: template.categoryCode
                )
            )
        }
        guard !collected.isEmpty else { throw SummaryTemplateCatalogError.emptyCatalog }
        return collected
    }
}
