import Foundation

/// A skill is a folder under `~/.voxstudio/skills/<id>/` with a `SKILL.md` file
struct Skill: Identifiable, Sendable {
    let id: String  // folder name
    let name: String
    let description: String
    let path: URL  // the SKILL.md file
    var category: String?
    var metadata: KnowledgeSkillMetadata?
    
    init(id: String, name: String, description: String, path: URL, category: String? = nil, metadata: KnowledgeSkillMetadata? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
        self.category = category
        self.metadata = metadata
    }
}

/// Extended metadata for Knowledge Base skills (category: knowledge / knowledge-qa).
/// Non-KB skills omit these fields.
struct KnowledgeSkillMetadata: Sendable {
    var selectionSummary: String?
    var appliesWhen: String?
    var allowedTools: [String]
    var supportsEvidenceGoals: [String]
    var analysisModes: [String]
    
    init(
        selectionSummary: String? = nil,
        appliesWhen: String? = nil,
        allowedTools: [String] = [],
        supportsEvidenceGoals: [String] = [],
        analysisModes: [String] = []
    ) {
        self.selectionSummary = selectionSummary
        self.appliesWhen = appliesWhen
        self.allowedTools = allowedTools
        self.supportsEvidenceGoals = supportsEvidenceGoals
        self.analysisModes = analysisModes
    }
}

enum SkillFrontmatter {
    /// Splits a SKILL.md into its frontmatter fields and body.
    /// Supports both single-line `key: value` and YAML-style list fields:
    ///   allowed_tools:
    ///     - tool.name
    ///     - another.tool
    static func parse(_ text: String) -> (fields: [String: String], lists: [String: [String]], body: String) {
        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fields, lists, text)
        }
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let valueStart = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    if valueStart.isEmpty {
                        var items: [String] = []
                        var j = i + 1
                        while j < lines.count {
                            let itemLine = lines[j]
                            let trimmed = itemLine.trimmingCharacters(in: .whitespaces)
                            if trimmed == "---" { break }
                            if trimmed.hasPrefix("-") {
                                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                                if !item.isEmpty { items.append(item) }
                                j += 1
                            } else if itemLine.contains(":") {
                                break
                            } else if !trimmed.isEmpty {
                                j += 1
                            } else {
                                j += 1
                            }
                        }
                        if !items.isEmpty {
                            lists[key] = items
                            i = j - 1
                        }
                    } else {
                        var value = valueStart
                        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                            value = String(value.dropFirst().dropLast())
                        }
                        fields[key] = value
                    }
                }
            }
            i += 1
        }
        let body = i + 1 < lines.count
            ? lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (fields, lists, body)
    }

    static func requiredFields(_ text: String) -> (name: String, description: String, category: String?, metadata: KnowledgeSkillMetadata?, body: String)? {
        let (fields, lists, body) = parse(text)
        guard let name = fields["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let description = fields["description"],
              !description.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let category = fields["category"]
        let isKBSkill = category == "knowledge" || category == "knowledge-qa"
        let metadata = isKBSkill ? KnowledgeSkillMetadata(
            selectionSummary: fields["selection_summary"],
            appliesWhen: fields["applies_when"],
            allowedTools: lists["allowed_tools"] ?? [],
            supportsEvidenceGoals: lists["supports_evidence_goals"] ?? [],
            analysisModes: lists["analysis_modes"] ?? []
        ) : nil
        return (name, description, category, metadata, body)
    }

    static func replacingName(_ text: String, name: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return "---\nname: \(name)\n---\n\n" + text
        }
        var front: [String] = []
        var replaced = false
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            if let colon = lines[i].firstIndex(of: ":"),
               lines[i][..<colon].trimmingCharacters(in: .whitespaces) == "name" {
                front.append("name: \(name)"); replaced = true
            } else {
                front.append(lines[i])
            }
            i += 1
        }
        if !replaced { front.insert("name: \(name)", at: 0) }
        let rest = i < lines.count ? lines[i...].joined(separator: "\n") : "---"
        return "---\n" + front.joined(separator: "\n") + "\n" + rest
    }
}
