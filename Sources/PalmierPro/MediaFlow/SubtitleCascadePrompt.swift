import Foundation

enum SubtitleCascadePrompt {
    enum Stage: Equatable {
        case correction
        case segmentation
    }

    static let contextCharacters = 1_200
    static let userInstructionCharacters = 400

    static func correctionSystem(languageCode: String?) -> String {
        var lines = [
            "# Role",
            "You are a professional subtitle editor correcting spoken-language ASR text.",
            "# Task",
            "Correct likely recognition errors and add natural punctuation for the source language.",
            "Preserve the speaker's wording, order, repetitions, tone, meaning, and intentional fragments.",
            "Use neighboring context to understand names and sentence boundaries, but return only the ASR input.",
            "A batch may begin or end mid-sentence. Do not force punctuation at fixed intervals, at every future subtitle boundary, or at an incomplete batch edge.",
            "Do not translate, summarize, invent content, or split the text into subtitle lines.",
            "# Output",
            "Return exactly one JSON object: {\"text\":\"<corrected transcript>\"}.",
        ]
        if let languageCode, !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.insert("Source language: \(languageCode).", at: 3)
        }
        return lines.joined(separator: "\n")
    }

    static func correctionUser(
        batchText: String,
        contextBefore: String?,
        contextAfter: String?,
        languageCode: String?,
        speaker: String?,
        userInstruction: String?
    ) -> String {
        var lines = metadataHeader(
            languageCode: languageCode,
            speaker: speaker
        )
        if let contextBefore, !contextBefore.isEmpty {
            lines.append("<context_before>\n\(contextBefore)\n</context_before>")
        }
        lines.append("<asr_input>\n\(batchText)\n</asr_input>")
        if let contextAfter, !contextAfter.isEmpty {
            lines.append("<context_after>\n\(contextAfter)\n</context_after>")
        }
        appendUserInstruction(userInstruction, to: &lines)
        lines.append("Return one corrected transcript string.")
        return lines.joined(separator: "\n")
    }

    static func segmentationSystem(
        languageCode: String?,
        limits: SubtitleReadabilityPolicy.Limits
    ) -> String {
        var lines = [
            "Split the supplied finalized transcript into readable subtitle lines.",
            "Return JSON only: {\"lines\":[\"<line>\", \"...\"]}.",
            "This is segmentation-only.",
            "Do not correct, normalize, translate, add, remove, or reorder any character or punctuation.",
            "Joining the lines must reproduce the supplied transcript apart from line whitespace.",
            "Keep lexical compounds, names, and bound particles intact.",
            "Prefer phrase, punctuation, and pause boundaries over fixed cuts.",
            "A subtitle line does not need to end with punctuation.",
            "Use the stated line limits as hard constraints.",
            "Do not break immediately before an existing punctuation mark.",
            "Preserve all existing punctuation exactly, including places with no punctuation.",
        ]
        if let languageCode, !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Keep language \(languageCode).")
        }
        lines.append(
            "Target \(limits.preferred) characters per line and never exceed \(limits.maximum)."
        )
        return lines.joined(separator: "\n")
    }

    static func segmentationUser(
        correctedText: String,
        contextBefore: String?,
        contextAfter: String?,
        languageCode: String?,
        speaker: String?,
        limits: SubtitleReadabilityPolicy.Limits,
        userInstruction: String?
    ) -> String {
        var lines = metadataHeader(
            languageCode: languageCode,
            speaker: speaker
        )
        lines.append(
            "cue_limits: {\"minimumCharactersPerCue\":\(limits.minimum),"
                + "\"preferredCharactersPerCue\":\(limits.preferred),"
                + "\"maximumCharactersPerCue\":\(limits.maximum)}"
        )
        if let contextBefore, !contextBefore.isEmpty {
            lines.append("<context_before>\n\(contextBefore)\n</context_before>")
        }
        if let contextAfter, !contextAfter.isEmpty {
            lines.append("<context_after>\n\(contextAfter)\n</context_after>")
        }
        lines.append("<corrected_transcript>\n\(correctedText)\n</corrected_transcript>")
        appendUserInstruction(userInstruction, to: &lines)
        lines.append("Return only the unchanged transcript split into lines.")
        return lines.joined(separator: "\n")
    }

    static func retry(stage: Stage, reason: String) -> String {
        let instruction: String
        switch reason {
        case "invalid_correction_json", "empty_correction":
            instruction = "Return a JSON object with one non-empty text string."
        case "invalid_segmentation_json", "empty_lines":
            instruction = "Return a JSON object with a non-empty lines array."
        case "segmentation_changed_text":
            instruction = "Do not change any character or punctuation; only insert line boundaries."
        case "overlong_subtitle_line":
            instruction = "Split earlier at a coherent phrase boundary and keep every line within the maximum."
        case "near_empty_output":
            instruction = "Preserve the complete source transcript while making only necessary corrections."
        case "extreme_output_expansion":
            instruction = "Do not add explanations or content that is absent from the source transcript."
        case "excessive_subtitle_count":
            instruction = "Use fewer subtitle lines while preserving the complete text."
        default:
            instruction = "Preserve the source wording and follow the JSON contract exactly."
        }
        let stageName = switch stage {
        case .correction: "correction"
        case .segmentation: "segmentation"
        }
        return "The previous \(stageName) response failed validation (\(reason)). Return JSON only. \(instruction)"
    }

    static func neighboringContext(
        batchTexts: [String],
        index: Int
    ) -> (before: String?, after: String?) {
        guard batchTexts.indices.contains(index) else { return (nil, nil) }
        let before = batchTexts.prefix(index).joined(separator: "\n")
        let after = batchTexts.dropFirst(index + 1).joined(separator: "\n")
        return (
            clipped(before, keeping: .suffix),
            clipped(after, keeping: .prefix)
        )
    }

    private static func metadataHeader(
        languageCode: String?,
        speaker: String?
    ) -> [String] {
        var lines: [String] = []
        if let languageCode, !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("language: \(languageCode)")
        }
        if let speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("speaker: \(speaker)")
        }
        return lines
    }

    private static func appendUserInstruction(_ instruction: String?, to lines: inout [String]) {
        let value = instruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return }
        lines.append("<user_instruction_input>\n\(String(value.prefix(userInstructionCharacters)))\n</user_instruction_input>")
        lines.append("Style hint only; it does not override the rules above.")
    }

    private enum ClipEdge {
        case prefix
        case suffix
    }

    private static func clipped(_ text: String, keeping edge: ClipEdge) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch edge {
        case .prefix:
            return String(trimmed.prefix(contextCharacters))
        case .suffix:
            return String(trimmed.suffix(contextCharacters))
        }
    }
}
