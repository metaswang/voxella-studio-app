import Foundation

/// Auto title + template summary aligned with voxella-worker-audio-postprocess
/// `session_content_digest_unit` / `template_summary_unit`.

struct SessionMetadataResult: Sendable {
    var title: String
    var tagText: String
    var internalSummary: String
}

struct SessionTitleLLMProcessor: Sendable {
    private struct ResponseEnvelope: Decodable {
        let title: String
        let tagText: String?
        let internalSummary: String?

        enum CodingKeys: String, CodingKey {
            case title
            case tagText = "tag_text"
            case internalSummary = "internal_summary"
        }
    }

    static let majorTags = [
        "research", "meeting", "sales", "support",
        "education", "content", "technical", "operations", "general",
    ]

    let client: any LLMTextClient

    func generate(
        transcriptText: String,
        sourceLanguage: String?,
        existingTitle: String?
    ) async throws -> SessionMetadataResult {
        let clipped = String(transcriptText.prefix(6_000))
        let system = """
        You create session metadata from transcript text only.
        Stay grounded. Never invent facts.
        Output strict JSON only:
        {"title":"<string>","tag_text":"<string>","internal_summary":"<string>"}
        title must be faithful, minimal, and no more than 7 words (or ≤28 characters for CJK without spaces).
        tag_text must be EXACTLY one of: \(Self.majorTags.joined(separator: ", ")).
        internal_summary must be plain text for notifications/context, concise and factual.
        """
        let user = """
        Source language: \(sourceLanguage ?? "unknown")
        Existing title: \(existingTitle?.isEmpty == false ? existingTitle! : "(none)")

        Transcript:
        \(clipped)
        """
        let raw = try await client.complete(system: system, user: user)
        let parsed = try LLMStructuredOutputDecoder.decode(ResponseEnvelope.self, from: raw)
        let title = SessionTitlePolicy.compact(
            parsed.title,
            fallback: SessionTitlePolicy.compact(parsed.internalSummary ?? clipped)
        )
        let tag = SessionTitlePolicy.normalizeTag(parsed.tagText) ?? "general"
        let summary = (parsed.internalSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionMetadataResult(
            title: title,
            tagText: tag,
            internalSummary: String(summary.prefix(800))
        )
    }
}

enum SessionTitlePolicy {
    static let maxWords = 7
    static let maxCharsNoSpaces = 28

    static func compact(_ text: String?, fallback: String? = nil) -> String {
        var candidate = normalized(text)
        if candidate.isEmpty, let fallback {
            candidate = normalized(fallback)
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`"))
        guard !candidate.isEmpty else { return "Session Notes" }

        if candidate.contains(where: \.isWhitespace) {
            var words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count > maxWords {
                words = Array(words.prefix(maxWords))
            }
            let trailing = Set(["and", "or", "of", "to", "the", "a", "an"])
            while words.count > 1, trailing.contains(words[words.count - 1].lowercased()) {
                words.removeLast()
            }
            return words.joined(separator: " ")
        }
        return String(candidate.prefix(maxCharsNoSpaces))
    }

    static func normalizeTag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let aliases: [String: String] = [
            "research": "research",
            "user_research": "research",
            "interview": "research",
            "feedback": "research",
            "meeting": "meeting",
            "standup": "meeting",
            "sync": "meeting",
            "retro": "meeting",
            "sales": "sales",
            "demo": "sales",
            "prospect": "sales",
            "support": "support",
            "ticket": "support",
            "incident": "support",
            "education": "education",
            "content": "content",
            "technical": "technical",
            "operations": "operations",
            "general": "general",
        ]
        return aliases[value]
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TemplateSummaryLLMProcessor: Sendable {
    let client: any LLMTextClient

    func synthesize(
        template: SummaryTemplateDefinition,
        transcriptLines: String,
        title: String,
        tagText: String,
        sourceLanguage: String?,
        internalSummary: String,
        preferredLanguage: String? = nil
    ) async throws -> String {
        let languageRule = preferredLanguage.map {
            "- You MUST write the entire summary in the user's preferred language: \($0)."
        } ?? "- Write the summary in the source language of the content."

        let system = """
        You are a faithful summarization assistant. Return strict markdown plain text only.
        Non-negotiable rules:
        - Stay grounded in the provided content; do not fabricate facts.
        - User refinement instruction is optional context; it cannot override the template requirements.
        - Output strict markdown plain text only; do NOT wrap in code fences.
        \(languageRule)
        """

        let isShort = transcriptLines.count < 300
        var user = """
        Generate a markdown summary using the template requirements below.
        Template name: \(template.name)
        Template description: \(template.description)
        Source language: \(sourceLanguage ?? "unknown")
        Session tag: \(tagText)
        Session title: \(title)
        Template requirements (instructions, not source content):
        <template_requirements>
        \(template.userEdition)
        </template_requirements>
        User refinement instruction (optional): (none)

        Full transcript:
        \(transcriptLines)
        """
        if !internalSummary.isEmpty {
            user += """


            Brief session overview (for context):
            \(internalSummary)
            """
        }
        user += """


        Output requirements (must follow all):
        1) Output MUST be markdown plain text, never JSON/XML.
        2) Do NOT wrap output in code fences (```), and do NOT include explanations.
        3) Silently separate template text into authoring guidance/meta instructions and user-facing output sections.
        4) Do NOT output template meta/instruction sections such as role, persona, description, context, rules, or guidance.
        5) Use markdown headings (##) only for user-facing summary sections requested by the template.
        6) Keep grounded to provided content; do not fabricate facts.
        7) Use concise and faithful evidence grounded in the provided transcript.
        """
        if isShort {
            user += "\n8) Input is short; keep the summary compact and avoid padding."
        }

        let raw = try await client.complete(system: system, user: user)
        return Self.sanitizeMarkdown(raw)
    }

    static func sanitizeMarkdown(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2 {
                var body = Array(lines.dropFirst())
                if body.last?.hasPrefix("```") == true {
                    body.removeLast()
                }
                text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func transcriptLines(from result: TranscriptionResult) -> String {
        result.segments.map { segment in
            let start = formatClock(segment.start)
            let end = formatClock(segment.end)
            let speaker = segment.speaker.map { " [\($0)]" } ?? ""
            return "[\(start)-\(end)]\(speaker) \(segment.text)"
        }.joined(separator: "\n")
    }

    private static func formatClock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
