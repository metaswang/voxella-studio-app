import Foundation

/// Summary template definitions for local Studio postprocess.
/// Auto-summary uses a general adaptive template (not domain-specific Interview Notes).

struct SummaryTemplateDefinition: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var userEdition: String
    var isFallback: Bool
    var categoryCode: String?

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
        6) Omit any section that would be empty or speculative.
        7) Keep the summary compact but information-dense.

        ## Suggested sections (include only what fits the content)
        - **Overview** (required, short paragraph): What this session is about and why it matters.
        - **Key Points** (required, bullets): The highest-value takeaways a busy reader would want first.
        - **Details & Facts** (optional, bullets): Specifics — products, offers, prices, dates, places, technical constraints, evidence.
        - **Decisions & Actions** (optional, bullets): Explicit decisions, commitments, next steps, owners/due dates if stated.
        - **Notable Quotes** (optional, bullets): A few high-signal lines with brief context.
        - **Open Questions / Risks** (optional, bullets): Unresolved questions, risks, or follow-ups implied by the source.

        Choose section set and ordering dynamically so a meeting, a class lecture, and a short promo each feel correctly summarized — not forced into an interview template.
        """,
        isFallback: true,
        categoryCode: "general"
    )

    /// Local Studio temporarily supports only the general adaptive template.
    static var locallySupported: [SummaryTemplateDefinition] {
        [generalSummary]
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
            return "Sign in at voxstudio.me to use custom summary templates."
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
        .generalSummary
    }

    /// Requires network + sign-in. Local Studio currently does not apply remote custom templates.
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
            Log.project.warning(
                "summary template fetch failed: \(error.localizedDescription); using bundled general template"
            )
            return SummaryTemplateDefinition.locallySupported
        }
    }

    private func filterLocallySupported(
        _ templates: [SummaryTemplateDefinition]
    ) -> [SummaryTemplateDefinition] {
        // Prefer local general template; remote catalog is informational until custom templates ship.
        _ = templates
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
                                ?? SummaryTemplateDefinition.generalSummary.userEdition,
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
                        ?? SummaryTemplateDefinition.generalSummary.userEdition,
                    isFallback: template.isFallback ?? false,
                    categoryCode: template.categoryCode
                )
            )
        }
        guard !collected.isEmpty else { throw SummaryTemplateCatalogError.emptyCatalog }
        return collected
    }
}
