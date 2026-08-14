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
    static let untitledPlaceholder = "Untitled project"
    static let autoGeneratePlaceholder = "Leave blank to auto-generate"

    /// True when the user typed a title in the input; empty / default placeholders stay auto-fillable.
    static func isUserProvided(_ title: String?) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return false }
        return trimmed.caseInsensitiveCompare(untitledPlaceholder) != .orderedSame
    }

    static func normalizedUserTitle(_ title: String?) -> String? {
        guard isUserProvided(title) else { return nil }
        return title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        preferredLanguage: String? = nil,
        userInstruction: String? = nil
    ) async throws -> String {
        let languageRule = preferredLanguage.map {
            "- You MUST write the entire summary in the user's preferred language: \($0)."
        } ?? "- Write the summary in the source language of the content."
        let refinement = userInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let refinementText = refinement.isEmpty ? "(none)" : refinement

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
        User refinement instruction (optional):
        <user_refinement>
        \(refinementText)
        </user_refinement>

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
        8) Never emit a heading with an empty body. If a section would be empty, omit the heading.
        """
        if isShort {
            user += "\n9) Input is short; keep the summary compact and avoid padding."
        } else {
            user += "\n9) Cover the full session. Unused concrete facts belong in a details section, not omitted after Key Points."
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
        return dropEmptyHeadingSections(text)
    }

    static func dropEmptyHeadingSections(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var heading: String?
        var body: [String] = []
        var kept: [String] = []

        func flush() {
            if let heading {
                let content = body.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard !content.isEmpty else { return }
                if !kept.isEmpty { kept.append("") }
                kept.append(heading)
                kept.append(contentsOf: trimSectionBody(body))
            } else if !body.isEmpty {
                kept.append(contentsOf: body)
            }
            heading = nil
            body.removeAll()
        }

        for line in lines {
            if isUserFacingHeading(line) {
                flush()
                heading = line.trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUserFacingHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("## ") && !trimmed.hasPrefix("###")
    }

    private static func trimSectionBody(_ body: [String]) -> [String] {
        var lines = body
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
        return lines
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
