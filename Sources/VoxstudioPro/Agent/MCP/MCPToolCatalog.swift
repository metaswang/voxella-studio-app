import Foundation
import MCP

/// Profile membership is enforced at listing and dispatch, independently of host visibility.
enum MCPToolCatalog {
    static let coreInstructions = """
    Local VoxStudio: original session evidence, transcription and voiceover. Cloud and
    voxstudio_native are separate connections. Keep workspace/turn, job, input, document
    and preview grants on this connection. Across connections reread real session/project
    IDs and validate access; never transfer temporary grants. Writes require a fresh UUID
    request_id; preserve it only on retries within one hour and the same App lifetime.
    For questions begin with app_knowledge(action=begin, query, request_id), pass its
    workspace_id/turn_id to evidence tools, fetch originals before citing, and finish
    with knowledge.complete_turn. Without MCP Apps read evidence directly.
    app_transcription submits either a user-supplied path or host attachment with start=true.
    voice.list then app_dubbing(text, voice_id, start=true) submits voiceover. Follow
    next_call using exact job/session IDs. Poll media.status until terminal; use fetch
    for transcript text, media.session_preview to audition, and media.export for results.
    Panel-only tools are internal UI operations. Editing uses voxstudio_native.
    """ + MCPKnowledgeBaseTools.instructions

    static let coreModelNames: Set<String> = [
        "voxstudio.workspace", "app_knowledge", "search", "fetch", "list_sources",
        "aggregate", "find_text", "methods", "knowledge.complete_turn",
        "app_transcription", "app_dubbing", "voxstudio.job_status", "voice.list",
        "voice.preview", "media.status", "media.session_preview", "media.export",
    ]
    private static let coreAppNames: Set<String> = [
        "app_workbench", "app_session", "app_evidence", "knowledge.workspace_state", "knowledge.update_view",
        "session.open", "voxstudio.sessions", "voxstudio.file_panel", "search_mentions",
        "media.choose_local_file", "media.bind_attachment", "media.input_status", "media.asset_preview",
        "transcription.create_from_input", "transcription.start_form", "transcription.translate_form",
        "transcription.translate", "transcription.segment", "transcription.select_track",
        "session.editor.read", "session.get_summary", "documents.export", "documents.export_form",
        "documents.read", "documents.save_as", "media.save_result", "media.preview",
    ]
    private static let descriptions: [String: String] = [
        "app_knowledge": "Begin a question with query and UUID request_id, or show its reader. Keep workspace_id/turn_id together for evidence reads and completion.",
        "app_transcription": "Submit a user-supplied local path or host attachment with start=true; omit language/speakers for detection. Otherwise prepare the panel. Follow next_call with exact IDs.",
        "app_dubbing": "Submit the user's text and a saved voice_id from voice.list with start=true; otherwise prepare a draft. session_id alone reopens a result. Follow next_call; do not submit twice.",
        "voxstudio.job_status": "Resolve this connection's job_id. Follow next_call with the returned session_id; never find submitted jobs by title.",
        "knowledge.complete_turn": "Finish this question with outcome and evidence/observation IDs from successful original reads. Does not generate an answer.",
    ]
    static func isModelTool(_ tool: Tool) -> Bool {
        tool._meta?.fields["ui"]?.objectValue?["visibility"]?.arrayValue != [.string("app")]
    }
    static func coreTools(from tools: [Tool]) -> [Tool] {
        tools.filter { coreModelNames.contains($0.name) || coreAppNames.contains($0.name) }.map { tool in
            var meta = tool._meta?.fields ?? [:]
            if !coreModelNames.contains(tool.name) {
                var ui = meta["ui"]?.objectValue ?? [:]; ui["visibility"] = ["app"]
                meta["ui"] = .object(ui)
            }
            return Tool(name: tool.name, title: tool.title, description: descriptions[tool.name] ?? tool.description,
                inputSchema: tool.inputSchema, annotations: tool.annotations,
                outputSchema: ["type": "object"], _meta: .init(additionalFields: meta))
        }
    }
    static func nativeTools(from tools: [Tool]) -> [Tool] {
        let presentation = Set(MCPWorkspaceTools.tools.map(\.name))
        let coreOnly: Set<String> = [
            "app_transcription", "app_dubbing", "transcription.create", "dubbing.create", "media.export",
            "session.open", "voxstudio.sessions", "voxstudio.file_panel", "search_mentions",
            "media.choose_local_file", "media.bind_attachment", "media.input_status", "media.asset_preview",
            "transcription.create_from_input", "transcription.start_form", "transcription.translate_form",
            "documents.export", "documents.export_form", "media.save_result", "media.session_preview",
        ]
        // Keep shared readers and document job polling; their grants remain profile-local.
        return tools.filter { !presentation.contains($0.name) && !coreOnly.contains($0.name) }.map { tool in
            Tool(name: tool.name, title: tool.title, description: tool.description.map { String($0.prefix(320)) },
                inputSchema: tool.inputSchema, annotations: tool.annotations, outputSchema: tool.outputSchema, _meta: tool._meta)
        }
    }
    static func coreResult(_ result: CallTool.Result) -> CallTool.Result {
        guard var fields = result.structuredContent?.objectValue else { return result }
        // The legacy data gateway remains app-only; the model follows explicit operation schemas.
        if var next = fields["next_call"]?.objectValue, next["tool"] == "app_evidence",
           var arguments = next["arguments"]?.objectValue, let action = arguments.removeValue(forKey: "action")?.stringValue {
            let name = action == "complete_turn" ? "knowledge.complete_turn" : action
            if action == "methods" { arguments["action"] = arguments.removeValue(forKey: "method_action") }
            next["tool"] = .string(name); next["arguments"] = .object(arguments); fields["next_call"] = .object(next)
        }
        if fields["evidence_provider"] != nil { fields["evidence_provider"] = ["server": "voxstudio", "backend": "local_mcp"] }
        if fields["transcript_tool"] != nil { fields["transcript_tool"] = "fetch" }
        if let session = fields["session_id"], fields["status"] == "completed" {
            if fields["kind"] == "dubbing" {
                fields["next_call"] = ["tool": "media.session_preview", "arguments": ["session_id": session]]
            } else {
                fields["next_call"] = ["tool": "fetch", "arguments": ["source_id": session, "view": "body"]]
            }
        }
        var updated = MCPWorkspaceTools.result(.object(fields), error: result.isError == true)
        updated._meta = result._meta
        return updated
    }
}
