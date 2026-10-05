import AppKit
import AVFoundation
import Foundation
import MCP
import UniformTypeIdentifiers

enum OpenAICreateElicitation: MCP.Method {
    static let name = "openai/elicitation/create"
    typealias Parameters = CreateElicitation.Parameters.FormParameters
    typealias Result = CreateElicitation.Result
}

/// One instance per MCP connection. Host metadata and grants never leak to another client.
@MainActor
final class MCPOpenAIExtensions {
    // Hosts cache panel HTML and CSP by URI. Bump these when shipping panel changes;
    // legacy URIs remain readable for clients with older tool metadata.
    nonisolated static let uiURI = "ui://voxstudio/library/v3"
    nonisolated static let transcriptionUIURI = "ui://voxstudio/transcription/v4"
    nonisolated static let sessionUIURI = "ui://voxstudio/session/v7"
    nonisolated static let dubbingUIURI = "ui://voxstudio/dubbing/v3"
    nonisolated static let uiResources: [(name: String, uri: String, file: String)] = [
        ("VoxStudio · Sessions", uiURI, "library"),
        ("VoxStudio · Transcribe", transcriptionUIURI, "transcription"),
        ("VoxStudio · Session", sessionUIURI, "session"),
        ("VoxStudio · Voiceover", dubbingUIURI, "dubbing"),
    ]
    nonisolated static let legacyUIURIs: [String: String] = [
        "ui://voxstudio/workbench/v1": uiURI,
        "ui://voxstudio/library/v2": uiURI,
        "ui://voxstudio/transcription/v1": transcriptionUIURI,
        "ui://voxstudio/transcription/v2": transcriptionUIURI,
        "ui://voxstudio/transcription/v3": transcriptionUIURI,
        "ui://voxstudio/session/v1": sessionUIURI,
        "ui://voxstudio/session/v2": sessionUIURI,
        "ui://voxstudio/session/v3": sessionUIURI,
        "ui://voxstudio/session/v4": sessionUIURI,
        "ui://voxstudio/session/v5": sessionUIURI,
        "ui://voxstudio/session/v6": sessionUIURI,
        "ui://voxstudio/dubbing/v1": dubbingUIURI,
        "ui://voxstudio/dubbing/v2": dubbingUIURI,
    ]
    nonisolated static func panelURI(for tool: String) -> String? {
        switch tool {
        case "app_workbench", "voxstudio.library": return uiURI
        case "app_transcription": return transcriptionUIURI
        case "app_session", "voxstudio.session_panel": return sessionUIURI
        case "app_dubbing": return dubbingUIURI
        case "voxstudio.file_panel": return transcriptionUIURI
        default: return nil
        }
    }
    nonisolated static let mediaExtensions = ["m4a", "wav", "mp3", "aac", "flac", "mp4", "mov"]
    private var capabilities = Client.Capabilities()
    private var formActive = false
    private var assets: [UUID: Asset] = [:]
    private var documents: Set<UUID> = []
    private var openedFiles: Set<String> = []
    private var previews: [String: (URL, String)] = [:]
    private var receipts: [String: (String, CallTool.Result)] = [:]
    private var jobs: [String: CallTool.Result] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private weak var server: Server?
    private let documentStore: MCPDocumentStore
    private let inputRoot: URL
    private let attachmentDownloader: (URLRequest) async throws -> (URL, URLResponse)
    private let mediaExecutor: @MainActor (String, [String: Any]) async -> ToolResult
    private let fileChooser: @MainActor (Bool) async throws -> URL?
    struct Asset { let url: URL; let name: String; var state: String; var error: String? }
    var owner: String? { AccountService.shared.userID?.uuidString }
    init(server: Server, documentStore: MCPDocumentStore = .shared, inputRoot: URL? = nil,
         attachmentDownloader: @escaping (URLRequest) async throws -> (URL, URLResponse) = { try await URLSession.shared.download(for: $0) },
         mediaExecutor: @escaping @MainActor (String, [String: Any]) async -> ToolResult = { await MCPMediaTools.execute(name: $0, args: $1) },
         fileChooser: @escaping @MainActor (Bool) async throws -> URL? = { try await MCPLocalFilePicker.shared.choose(media: $0) }) {
        self.server = server; self.documentStore = documentStore
        self.inputRoot = inputRoot ?? AppSupportPaths.applicationSupport().appendingPathComponent("MCP/Inputs")
        self.attachmentDownloader = attachmentDownloader; self.mediaExecutor = mediaExecutor
        self.fileChooser = fileChooser
    }
    func initialize(_ capabilities: Client.Capabilities) { self.capabilities = capabilities }
    var supportsForm: Bool { capabilities.extensions?["openai/elicitation"]?.objectValue?["form"]?.objectValue != nil }

    nonisolated static func schema(_ properties: [String: Value] = [:], required: [String] = []) -> Value {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": false])
    }
    nonisolated static func field(_ type: String) -> Value { .object(["type": .string(type)]) }
    nonisolated static var tools: [Tool] {
        let string = field("string"), number = field("number")
        let common: [String: Value] = ["session_id": string, "scope": .object(["type": "string", "enum": ["transcript", "source", "translation"]]), "language": string]
        let file = schema(["name": string, "resourceUri": string], required: ["name", "resourceUri"])
        // ChatGPT prompt attachments use fileParams, distinct from file-viewer resource URIs.
        let attachment = schema(["download_url": string, "file_id": string, "mime_type": string, "file_name": string], required: ["download_url", "file_id"])
        let definitions: [(String, String, Value, Bool)] = [
            ("app_workbench", "VoxStudio · Sessions", schema(), true),
            ("app_transcription", "Transcribe audio or video", schema([
                "path": .object(["type": "string", "description": "Local media path supplied by the user; absolute or ~/ path. Do not invent a path."]),
                "attachment": attachment,
                "start": .object(["type": "boolean", "description": "Set true when the user explicitly requests transcription of the path or ChatGPT attachment. Starts immediately without a file picker or options form. Default false opens the panel only.", "default": false]),
                "title": string,
                "language": .object(["type": "string", "description": "Omit or use auto to detect the spoken language automatically."]),
                "speakers": .object(["type": "string", "description": "off, auto, one, two, three, four; default auto"]),
                "segment_subtitles": field("boolean"),
                "target_languages": .object(["type": "array", "items": string]),
            ]), false),
            ("app_dubbing", "Create a voiceover", schema(), true),
            ("app_session", "View a VoxStudio session", schema(["session_id": string], required: ["session_id"]), true),
            ("session.open", "Open a session in the VoxStudio Mac app", schema(["session_id": string], required: ["session_id"]), false),
            ("voxstudio.sessions", "Read visible sessions for the library", schema(), true),
            ("media.save_result", "Save a completed voiceover audio file", schema(["session_id": string], required: ["session_id"]), false),
            ("voxstudio.library", "VoxStudio sessions", schema(), true),
            ("voxstudio.session_panel", "Session details", schema(["session_id": string]), true),
            ("voxstudio.file_panel", "Open an audio or video attachment for transcription; does not start a job", schema(["file": file], required: ["file"]), true),
            ("search_mentions", "Find visible VoxStudio sessions for composer mentions", schema(["query": string], required: ["query"]), true),
            ("media.choose_local_file", "Open the Mac audio/video picker and immediately return a selecting job_id. Poll voxstudio.job_status until cancelled or an asset_id is returned, then media.input_status until ready. Choosing a file does not start transcription.", schema(), false),
            ("media.bind_attachment", "Import the current host attachment into managed storage", schema(["file": file], required: ["file"]), false),
            ("media.input_status", "Read this connection's media import status", schema(["asset_id": string], required: ["asset_id"]), true),
            ("media.session_preview", "Generate bounded session audio/video with synchronized subtitles", schema(["session_id": string, "language": string, "start": number, "duration": number], required: ["session_id"]), false),
            ("media.asset_preview", "Generate a bounded audio/video preview of a selected input", schema(["asset_id": string, "start": number, "duration": number], required: ["asset_id"]), false),
            ("transcription.create_from_input", "Start a job from a ready managed input", schema(["asset_id": string, "title": string, "language": string, "speakers": string, "segment_subtitles": field("boolean"), "target_languages": .object(["type": "array", "items": string])], required: ["asset_id"]), false),
            ("transcription.start_form", "Ask for media and transcription options in a native form only when the user explicitly requests the host form; use app_transcription with path and start=true for a transcription request with a local path", schema(["asset_id": string]), false),
            ("transcription.translate_form", "Ask for target languages in a native form", schema(["session_id": string], required: ["session_id"]), false),
            ("voxstudio.job_status", "Resolve the exact job_id returned by a submission. For transcription, poll until session_id is returned, then poll media.status with that session_id and read app_session when completed. Never search the session list by filename/title to identify a submitted job; titles can change automatically.", schema(["job_id": string], required: ["job_id"]), true),
            ("documents.choose_local_file", "Open the Mac document picker and immediately return a selecting job_id. Poll voxstudio.job_status for the imported document or cancellation.", schema(), false),
            ("documents.import_text", "Save a host document copy in VoxStudio", schema(["name": string, "blob": string], required: ["name", "blob"]), false),
            ("documents.read", "Read a granted managed document", schema(["document_id": string], required: ["document_id"]), true),
            ("documents.commit", "Atomically save a managed document with conflict detection", schema(["document_id": string, "expected_revision": string, "text": string, "request_id": string], required: ["document_id", "expected_revision", "text", "request_id"]), false),
            ("documents.save_as", "Ask the user where to save a managed document copy", schema(["document_id": string], required: ["document_id"]), false),
            ("documents.export", "Export a session track into a managed text document", schema(common.merging(["format": string, "name": string, "bilingual": field("boolean")], uniquingKeysWith: { _, new in new }), required: ["session_id", "format"]), false),
            ("documents.export_form", "Ask for session export options in a native form", schema(common, required: ["session_id"]), false),
            ("session.editor.read", "Read session transcript or subtitle cues and revision, including read-only voiceover tracks", schema(common, required: ["session_id"]), true),
            ("session.editor.commit", "Apply an atomic cue-edit batch with expected revision", schema(common.merging(["expected_revision": string, "request_id": string, "operations": .object(["type": "array", "items": .object(["type": "object"])])], uniquingKeysWith: { _, new in new }), required: ["session_id", "expected_revision", "request_id", "operations"]), false),
            ("session.document.apply", "Explicitly apply a saved subtitle document to a chosen session track", schema(common.merging(["document_id": string, "document_revision": string, "expected_revision": string, "request_id": string], uniquingKeysWith: { _, new in new }), required: ["session_id", "document_id", "document_revision", "expected_revision", "request_id"]), false),
        ]
        return definitions.map { name, title, input, readOnly in
            var meta: [String: Value] = [:]
            if let uri = panelURI(for: name) {
                meta["ui"] = .object(["resourceUri": .string(uri)])
                // A single global entry avoids duplicate sidebar registrations. Separate task tools
                // can also be invoked directly by the model, with their own independent resource.
                if name == "voxstudio.library" {
                    meta["openai/ui"] = .object(["entrypoints": [.object(["type": "global"])]])
                } else if name == "voxstudio.session_panel" {
                    meta["openai/ui"] = .object(["entrypoints": [.object(["type": "thread"])]])
                } else if name == "voxstudio.file_panel" {
                    meta["openai/ui"] = .object(["entrypoints": [.object(["type": "file", "extensions": .array(mediaExtensions.map { .string("." + $0) })])]])
                }
            }
            if name == "voxstudio.sessions" || name == "media.save_result" || name == "session.open" {
                meta["ui"] = .object(["visibility": ["app"]])
            }
            if name == "search_mentions" {
                meta["openai/extensions"] = .object(["mentions/search": .object([:])])
                meta["ui"] = .object(["visibility": ["app"]])
            }
            if name == "app_transcription" { meta["openai/fileParams"] = ["attachment"] }
            let description = name == "app_transcription"
                ? "Transcribe audio/video in one call: pass either the exact local path from the prompt or the ChatGPT media attachment in attachment, plus start=true. Language and speakers are detected automatically when omitted. Follow the returned next_call: resolve job_id with voxstudio.job_status if session_id is not present, otherwise use media.status with that exact session_id. When completed, read app_session with the same session_id. Titles change automatically; do not find results by filename or repeatedly open session lists. No file picker or host form is needed. With start omitted/false, open the panel and optionally preselect the input without creating a job."
                : title
            return Tool(name: name, title: title, description: description, inputSchema: input, annotations: .init(readOnlyHint: readOnly, destructiveHint: name == "documents.commit" || name == "session.editor.commit" || name == "session.document.apply", idempotentHint: readOnly || name.hasSuffix(".commit"), openWorldHint: false), outputSchema: .object(["type": "object"]), _meta: .init(additionalFields: meta))
        }
    }

    static func result(_ value: [String: Any], error: Bool = false) throws -> CallTool.Result {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let structured = try JSONDecoder().decode(Value.self, from: data)
        return .init(content: [.text(String(decoding: data, as: UTF8.self))], structuredContent: Optional.some(structured), isError: error ? true : nil)
    }
    static func adapted(_ result: ToolResult) -> CallTool.Result {
        let base = result.toMCPResult()
        let value = result.content.compactMap { block -> Value? in
            guard case .text(let text) = block, let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Value.self, from: data)
        }.first
        return .init(content: base.content, structuredContent: value, isError: base.isError, _meta: base._meta)
    }
    func visibleSessions() -> [WorkbenchSession] {
        let allowed = KnowledgeSourceOrigin.effectiveOrigins(isSignedIn: AccountService.shared.isSignedIn)
        return WorkbenchStore.shared.sessions.filter { allowed.contains(KnowledgeSourceOrigin.resolve(isCloudStorage: $0.storage == .cloud, hasRemoteSessionID: $0.remoteSessionID != nil || $0.isRemoteOnly)) }
    }
    nonisolated static func sessionSummary(_ session: WorkbenchSession) -> [String: Any] {
        let material = KnowledgeTranscriptMaterial.from(session)
        var value: [String: Any] = [
            "session_id": session.id.uuidString, "title": session.title, "status": session.state.rawValue,
            "kind": session.source == .standaloneDub ? "dubbing" : "transcription",
            "created_at": ISO8601DateFormatter().string(from: session.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: session.modifiedAt),
            "translation_languages": session.translationTracks.map(\.languageCode),
            "has_result": session.hasUsableResult, "remote_only": session.isRemoteOnly,
        ]
        value["duration"] = session.duration
        value["language"] = material?.language
        value["has_transcript"] = material != nil
        return value
    }
    /// Give the model readable content when it opens a panel or resolves a mention.
    /// Catalog rows remain compact; longer bodies can be read through session.get_segments.
    nonisolated static func sessionDetails(_ session: WorkbenchSession) -> [String: Any] {
        var value = sessionSummary(session)
        let material = KnowledgeTranscriptMaterial.from(session)
        let text = material?.text ?? ""
        value["text"] = String(text.prefix(16_000))
        value["text_complete"] = material != nil && text.count <= 16_000
        value["content_provenance"] = material?.provenance
        value["content_role"] = material?.role
        value["content_revision"] = material?.revision
        value["transcript_tool"] = "session.get_segments"
        return value
    }

    nonisolated static func readableTrack(_ session: WorkbenchSession, scope: String, language: String?) throws -> SubtitleTrack {
        let track: SubtitleTrack?
        switch scope {
        case "transcript":
            track = KnowledgeTranscriptMaterial.displayTranscript(for: session).map(SubtitleTrack.fromTranscript)
        case "source":
            track = session.subtitleTrack
                ?? (session.source == .standaloneDub || session.sessionType == .dub ? session.dubSubtitleTrack : nil)
                ?? SubtitleTrack(sourceLanguage: KnowledgeTranscriptMaterial.from(session)?.language,
                                 language: KnowledgeTranscriptMaterial.from(session)?.language, cues: [])
        case "translation":
            guard let language, let translation = session.translationTracks.first(where: { $0.languageCode == language }) else {
                throw MCPDocumentError("not_found", "Choose an existing translation language")
            }
            track = translation.track
        default: throw MCPDocumentError("invalid_argument", "scope must be transcript, source or translation")
        }
        guard let track else { throw MCPDocumentError("not_ready", "Track has no cues") }
        return track
    }
    func execute(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
            guard let tool = Self.tools.first(where: { $0.name == params.name }) else { throw MCPDocumentError("unknown_tool", "Unknown extension tool") }
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            guard Set(args.keys).isSubset(of: Set(properties.keys)) else { throw MCPDocumentError("invalid_argument", "Unknown argument") }
            for (key, value) in params.arguments ?? [:] {
                let type = properties[key]?.objectValue?["type"]?.stringValue
                let valid: Bool
                switch type {
                case "string": valid = value.stringValue != nil
                case "boolean": valid = value.boolValue != nil
                case "object": valid = value.objectValue != nil
                case "array": valid = value.arrayValue != nil
                case "number": valid = value.intValue != nil || value.doubleValue != nil
                default: valid = false
                }
                guard valid else { throw MCPDocumentError("invalid_argument", "Invalid type for \(key)") }
                if let choices = properties[key]?.objectValue?["enum"]?.arrayValue, !choices.contains(value) { throw MCPDocumentError("invalid_argument", "Invalid value for \(key)") }
            }
            for key in tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard args[key] != nil else { throw MCPDocumentError("invalid_argument", "Missing \(key)") }
            }
            switch params.name {
            case "app_workbench", "voxstudio.library", "voxstudio.sessions":
                for _ in 0..<100 {
                    if !WorkbenchStore.shared.isHydrating { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !WorkbenchStore.shared.isHydrating else { throw MCPDocumentError("loading", "The session library is still loading. Please refresh shortly.") }
                var value: [String: Any] = ["view": "library", "native_forms": supportsForm,
                    "sessions": visibleSessions().sorted { $0.modifiedAt > $1.modifiedAt }.prefix(200).map(Self.sessionSummary)]
                // Keep the older library API's document grants, without coupling the focused
                // session UI to unrelated document storage or parsing failures.
                if params.name == "voxstudio.library" {
                    let docs = try await documentStore.list(owner: owner)
                    documents.formUnion(docs.map(\.id))
                    value["documents"] = docs.map { ["document_id": $0.id.uuidString, "name": $0.name, "revision": $0.revision] }
                }
                return try Self.result(value)
            case "app_session", "voxstudio.session_panel":
                var value: [String: Any] = ["view": "session", "native_forms": supportsForm]
                if let rawID = args["session_id"] as? String {
                    let id = try sessionID(rawID)
                    if let session = visibleSessions().first(where: { $0.id == id }) {
                        value.merge(Self.sessionDetails(session), uniquingKeysWith: { _, new in new })
                    }
                }
                return try Self.result(value)
            case "app_transcription":
                var value: [String: Any] = ["view": "transcription", "native_forms": supportsForm]
                let shouldStart = args["start"] as? Bool == true
                guard args["path"] == nil || args["attachment"] == nil else { throw MCPDocumentError("invalid_argument", "Provide either path or attachment, not both") }
                var options = args
                options.removeValue(forKey: "start")
                options.removeValue(forKey: "attachment")
                options.removeValue(forKey: "path")
                value["options"] = options
                if let attachment = args["attachment"] as? [String: Any] {
                    // Validate all options before starting a download or creating work.
                    var validation = options; validation["path"] = "/attachment"
                    try MCPMediaTools.validate(validation, name: "transcription.create")
                    let input = try bindPromptAttachment(attachment)
                    let data = ToolArgsBridge.argsFromMCP(input.structuredContent?.objectValue ?? [:])
                    value["name"] = data["name"]
                    if shouldStart {
                        let id = try assetID(data)
                        let queued = await submissionResult(try enqueueTranscription(id, options: options))
                        value.merge(ToolArgsBridge.argsFromMCP(queued.structuredContent?.objectValue ?? [:]), uniquingKeysWith: { _, new in new })
                        return try Self.result(value, error: queued.isError == true)
                    } else { value["input"] = data }
                    return try Self.result(value)
                }
                guard let path = args["path"] as? String else {
                    guard !shouldStart else { throw MCPDocumentError("invalid_argument", "path or attachment is required to start transcription") }
                    return try Self.result(value)
                }
                let url = try MCPMediaTools.localFile(path)
                options["path"] = url.path
                try MCPMediaTools.validate(options, name: "transcription.create")
                value["name"] = url.lastPathComponent
                options.removeValue(forKey: "path")
                value["options"] = options
                if shouldStart {
                    options["path"] = url.path
                    let queued = await submissionResult(try enqueueMedia("transcription.create", options))
                    value.merge(ToolArgsBridge.argsFromMCP(queued.structuredContent?.objectValue ?? [:]), uniquingKeysWith: { _, new in new })
                    return try Self.result(value, error: queued.isError == true)
                } else {
                    let input = try await bindMedia(url)
                    value["input"] = ToolArgsBridge.argsFromMCP(input.structuredContent?.objectValue ?? [:])
                }
                return try Self.result(value)
            case "session.open":
                let id = try sessionID(string(args, "session_id"))
                WorkbenchStore.shared.openSession(id)
                AppState.shared.showHome()
                HomeWindowController.shared.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return try Self.result(["outcome": "opened", "session_id": id.uuidString])
            case "app_dubbing":
                let voices = Self.adapted(await MCPMediaTools.execute(name: "voice.list", args: [:]))
                if voices.isError == true { return voices }
                var value = voices.structuredContent?.objectValue ?? [:]
                value["view"] = "dubbing"
                return .init(content: voices.content, structuredContent: .object(value))
            case "media.save_result":
                let id = try sessionID(string(args, "session_id"))
                guard let job = WorkbenchStore.shared.dubs.first(where: { $0.id == id }), job.state == .completed, let url = job.outputURL,
                      FileManager.default.fileExists(atPath: url.path) else { throw MCPDocumentError("not_ready", "A completed local voiceover is required") }
                let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
                let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
                guard response == .OK, let destination = panel.url else { return try Self.result(["outcome": "cancelled"]) }
                try Data(contentsOf: url).write(to: destination, options: .atomic)
                return try Self.result(["outcome": "saved", "name": destination.lastPathComponent])
            case "voxstudio.file_panel":
                let file = try fileInput(args)
                openedFiles.insert(file.uri)
                return try Self.result(["view": "file", "file": ["name": file.name, "resourceUri": file.uri], "native_forms": supportsForm])
            case "search_mentions":
                let query = try string(args, "query", allowEmpty: true)
                let items = visibleSessions().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.prefix(30).map {
                    ["type": "resource_link", "name": $0.title, "uri": "voxstudio://sessions/\($0.id.uuidString)", "mimeType": "application/json"]
                }
                return try Self.result(["items": Array(items)])
            case "media.choose_local_file", "documents.choose_local_file":
                return try enqueueFileSelection(media: params.name.hasPrefix("media."))
            case "media.bind_attachment":
                let file = try fileInput(args)
                guard openedFiles.contains(file.uri), let path = params._meta?["openai/resource"]?.objectValue?["path"]?.stringValue else {
                    throw MCPDocumentError("attachment_unavailable", "Open this attachment through the file entrypoint first")
                }
                return try await bindMedia(URL(fileURLWithPath: path))
            case "media.input_status": return try assetResult(try assetID(args))
            case "media.session_preview":
                let id = try sessionID(string(args, "session_id"))
                guard let job = WorkbenchStore.shared.transcriptions.first(where: { $0.id == id }), job.result != nil else { throw MCPDocumentError("not_ready", "Transcription media is not ready") }
                let source = URL(fileURLWithPath: job.sourcePath)
                return try await preview(FileManager.default.fileExists(atPath: source.path) ? source : job.playbackAudioURL, args: args, subtitles: MCPMediaTools.track(job, language: args["language"] as? String, allowTranscriptFallback: false))
            case "media.asset_preview":
                let id = try assetID(args), input = assets[id]!
                guard input.state == "ready" else { throw MCPDocumentError("input_not_ready", input.error ?? "Wait for media import") }
                return try await preview(input.url, args: args)
            case "transcription.create_from_input":
                let id = try assetID(args)
                guard assets[id]?.state == "ready" else { throw MCPDocumentError("input_not_ready", "Wait for media import") }
                var options = args; options.removeValue(forKey: "asset_id"); options["path"] = assets[id]!.url.path
                if options["title"] == nil { options["title"] = (assets[id]!.name as NSString).deletingPathExtension }
                try MCPMediaTools.validate(options, name: "transcription.create")
                return try enqueueMedia("transcription.create", options)
            case "transcription.start_form", "transcription.translate_form", "documents.export_form": return try await form(params.name, args)
            case "voxstudio.job_status":
                guard let job = jobs[try string(args, "job_id")] else { throw MCPDocumentError("not_found", "Job not found on this connection; refresh the session library") }
                return job
            case "documents.import_text":
                guard let bytes = Data(base64Encoded: try string(args, "blob", allowEmpty: true)) else { throw MCPDocumentError("invalid_argument", "Invalid base64 document") }
                return try await createDocument(name: string(args, "name"), bytes: bytes)
            case "documents.read": return try await documentResult(readDocument(args))
            case "documents.commit":
                let id = try documentID(args)
                let document = try await documentStore.commit(id, owner: owner, expected: string(args, "expected_revision"), text: string(args, "text", allowEmpty: true), requestID: string(args, "request_id"))
                return try documentResult(document)
            case "documents.save_as":
                let document = try await readDocument(args)
                let panel = NSSavePanel(); panel.nameFieldStringValue = document.name
                let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
                guard response == .OK, let url = panel.url else { return try Self.result(["outcome": "cancelled"]) }
                try document.bytes.write(to: url, options: .atomic)
                return try Self.result(["outcome": "saved", "name": url.lastPathComponent])
            case "documents.export": return try await exportDocument(args)
            case "session.editor.read": return try editorResult(args)
            case "session.editor.commit", "session.document.apply": return try await commitSession(params.name, args)
            default: throw MCPDocumentError("unknown_tool", "Unknown extension tool")
            }
        } catch let error as MCPDocumentError { return (try? Self.result(["outcome": error.code, "error": error.message], error: true)) ?? .init(isError: true) }
        catch is CancellationError { return (try? Self.result(["outcome": "cancelled"])) ?? .init() }
        catch { return (try? Self.result(["outcome": "failed", "error": error.localizedDescription], error: true)) ?? .init(isError: true) }
    }

    private func string(_ args: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPDocumentError("invalid_argument", "\(key) must be a string") }
        return value
    }
    private func fileInput(_ args: [String: Any]) throws -> (name: String, uri: String) {
        guard let file = args["file"] as? [String: Any] else { throw MCPDocumentError("invalid_argument", "file is required") }
        return (try string(file, "name"), try string(file, "resourceUri"))
    }
    private func sessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), visibleSessions().contains(where: { $0.id == id }) else { throw MCPDocumentError("not_found", "Session not visible") }
        return id
    }
    private func assetID(_ args: [String: Any]) throws -> UUID {
        guard let id = UUID(uuidString: try string(args, "asset_id")), assets[id] != nil else { throw MCPDocumentError("not_found", "Input not granted to this connection") }
        return id
    }
    private func documentID(_ args: [String: Any]) throws -> UUID {
        guard let id = UUID(uuidString: try string(args, "document_id")), documents.contains(id) else { throw MCPDocumentError("not_found", "Document not granted to this connection") }
        return id
    }
    private func readDocument(_ args: [String: Any]) async throws -> MCPDocumentStore.Document { try await documentStore.read(documentID(args), owner: owner) }
    private func documentResult(_ document: MCPDocumentStore.Document) throws -> CallTool.Result {
        let decoded = try MCPDocumentCodec.decode(document.bytes)
        var value: [String: Any] = ["outcome": "saved", "document_id": document.id.uuidString, "name": document.name, "format": document.format, "revision": document.revision, "text": decoded.text, "encoding": "UTF-8", "bom": decoded.bom, "newline": decoded.newline, "resource_uri": "voxstudio://documents/\(document.id.uuidString)"]
        do { try MCPDocumentCodec.validate(decoded.text, format: document.format); value["diagnostics"] = [] }
        catch { value["diagnostics"] = [error.localizedDescription] }
        return try Self.result(value)
    }
    private func createDocument(name: String, bytes: Data) async throws -> CallTool.Result {
        let document = try await documentStore.create(name: name, bytes: bytes, owner: owner)
        documents.insert(document.id)
        return try documentResult(document)
    }
    private func enqueueFileSelection(media: Bool) throws -> CallTool.Result {
        // User interaction must outlive a single host tools/call timeout.
        let id = UUID().uuidString
        let initial = try Self.result(["job_id": id, "status": "selecting", "message": "Choose a file in the VoxStudio window on your Mac."])
        jobs[id] = initial
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                guard let url = try await fileChooser(media) else {
                    jobs[id] = try Self.result(["outcome": "cancelled", "status": "cancelled"])
                    return
                }
                if media { jobs[id] = try await bindMedia(url) }
                else {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    jobs[id] = try await createDocument(name: url.lastPathComponent, bytes: Data(contentsOf: url))
                }
            } catch let error as MCPDocumentError {
                jobs[id] = try? Self.result(["outcome": error.code, "status": "failed", "error": error.message], error: true)
            } catch {
                jobs[id] = try? Self.result(["status": "failed", "error": error.localizedDescription], error: true)
            }
        }
        return initial
    }
    private func bindMedia(_ url: URL) async throws -> CallTool.Result {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true, values.isReadable == true,
              Self.mediaExtensions.contains(url.pathExtension.lowercased()) else { throw MCPDocumentError("invalid_media", "Choose a readable supported audio/video file") }
        let access = url.startAccessingSecurityScopedResource()
        let handle = try FileHandle(forReadingFrom: url)
        let id = UUID(), root = inputRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(id.uuidString + "." + url.pathExtension)
        assets[id] = Asset(url: destination, name: url.lastPathComponent, state: "importing")
        tasks[id.uuidString] = Task {
            defer { try? handle.close(); if access { url.stopAccessingSecurityScopedResource() }; tasks[id.uuidString] = nil }
            do {
                try await Task.detached {
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                    let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
                    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: data) }
                }.value
                try await validateMedia(destination)
                assets[id]?.state = "ready"
            } catch { assets[id]?.state = "failed"; assets[id]?.error = error.localizedDescription; try? FileManager.default.removeItem(at: destination) }
        }
        return try assetResult(id)
    }

    nonisolated static func promptAttachment(_ input: [String: Any]) throws -> (url: URL, name: String?, mimeType: String?) {
        guard Set(input.keys).isSubset(of: ["download_url", "file_id", "mime_type", "file_name"]),
              let rawURL = input["download_url"] as? String, let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let fileID = input["file_id"] as? String, !fileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input["file_name"] == nil || input["file_name"] is String,
              input["mime_type"] == nil || input["mime_type"] is String else {
            throw MCPDocumentError("invalid_attachment", "Use the actual ChatGPT media attachment with its file_id and HTTPS download_url")
        }
        let name = (input["file_name"] as? String).map { ($0 as NSString).lastPathComponent }
        return (url, name, input["mime_type"] as? String)
    }

    nonisolated static func attachmentName(_ name: String?, mimeType: String?) throws -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.mediaExtensions.contains(ext) { return name }
        let types = ["audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/vnd.wave": "wav",
                     "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                     "audio/aac": "aac", "audio/flac": "flac", "audio/x-flac": "flac",
                     "video/mp4": "mp4", "video/quicktime": "mov"]
        guard ext.isEmpty, let inferred = types[mimeType?.lowercased() ?? ""] else {
            throw MCPDocumentError("invalid_media", "Attachment must be a supported audio/video file")
        }
        return (name.isEmpty ? "Attached media" : name) + "." + inferred
    }

    private func bindPromptAttachment(_ input: [String: Any]) throws -> CallTool.Result {
        let descriptor = try Self.promptAttachment(input)
        let id = UUID(), root = inputRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The suffix may be supplied only by the download's Content-Type. Replace the
        // placeholder after downloading; user-provided names never become storage paths.
        assets[id] = Asset(url: root.appendingPathComponent(id.uuidString), name: descriptor.name ?? "Attached media", state: "importing")
        tasks[id.uuidString] = Task {
            defer { tasks[id.uuidString] = nil }
            var destination: URL?
            do {
                var request = URLRequest(url: descriptor.url); request.timeoutInterval = 120
                let (temporary, response) = try await attachmentDownloader(request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw MCPDocumentError("attachment_download_failed", "Could not download the ChatGPT attachment; provide a fresh attachment if its link expired")
                }
                try Task.checkCancellation()
                let name = try Self.attachmentName(descriptor.name, mimeType: descriptor.mimeType ?? response.mimeType)
                let url = root.appendingPathComponent(id.uuidString + "." + (name as NSString).pathExtension)
                destination = url
                try FileManager.default.moveItem(at: temporary, to: url)
                try await validateMedia(url)
                assets[id] = Asset(url: url, name: name, state: "ready")
            } catch {
                assets[id]?.state = "failed"; assets[id]?.error = error.localizedDescription
                if let destination { try? FileManager.default.removeItem(at: destination) }
            }
        }
        return try assetResult(id)
    }

    private func validateMedia(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio), video = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !audio.isEmpty || !video.isEmpty else { throw MCPDocumentError("invalid_media", "Media has no playable tracks or duration") }
    }

    private func enqueueTranscription(_ id: UUID, options: [String: Any]) throws -> CallTool.Result {
        let jobID = UUID().uuidString
        jobs[jobID] = try correlatedSubmission(["status": assets[id]?.state == "importing" ? "importing" : "queued"], id: jobID)
        tasks[jobID] = Task {
            while assets[id]?.state == "importing" { try? await Task.sleep(for: .milliseconds(200)) }
            if let asset = assets[id], asset.state == "ready" {
                var args = options; args["path"] = asset.url.path
                if args["title"] == nil { args["title"] = (asset.name as NSString).deletingPathExtension }
                jobs[jobID] = correlate(Self.adapted(await mediaExecutor("transcription.create", args)), id: jobID)
            } else { jobs[jobID] = try? correlatedSubmission(["status": "failed", "error": assets[id]?.error ?? "Input failed"], id: jobID, error: true) }
            tasks[jobID] = nil
        }
        return jobs[jobID]!
    }
    private func assetResult(_ id: UUID) throws -> CallTool.Result {
        let asset = assets[id]!
        var value: [String: Any] = ["asset_id": id.uuidString, "status": asset.state, "name": asset.name]
        if let error = asset.error { value["error"] = error }
        return try Self.result(value, error: asset.state == "failed")
    }
    private func enqueueMedia(_ name: String, _ args: [String: Any]) throws -> CallTool.Result {
        let id = UUID().uuidString
        jobs[id] = try correlatedSubmission(["status": "queued"], id: id)
        tasks[id] = Task {
            let result = Self.adapted(await mediaExecutor(name, args))
            jobs[id] = correlate(result, id: id); tasks[id] = nil
        }
        return jobs[id]!
    }

    private func correlatedSubmission(_ result: [String: Any], id: String, error: Bool = false) throws -> CallTool.Result {
        var value = result
        value["job_id"] = id
        if !error, let session = value["session_id"] as? String {
            value["next_call"] = ["tool": "media.status", "arguments": ["session_id": session]]
            value["result_call"] = ["tool": "app_session", "arguments": ["session_id": session]]
            value["message"] = result["message"] ?? "Your transcription has been submitted."
            value["instructions"] = "Session created. Use this exact session_id for progress and results, even if the title changes. When media.status is completed, read app_session. Do not search the session list by filename."
        } else if !error {
            value["next_call"] = ["tool": "voxstudio.job_status", "arguments": ["job_id": id]]
            value["message"] = "Preparing your transcription on your Mac."
            value["instructions"] = "Submission accepted; it has not returned a session_id yet. Poll voxstudio.job_status with this exact job_id until session_id is returned, then media.status and app_session. Do not retry creation or search the session list by filename."
        }
        return try Self.result(value, error: error)
    }

    private func correlate(_ result: CallTool.Result, id: String) -> CallTool.Result {
        var value = ToolArgsBridge.argsFromMCP(result.structuredContent?.objectValue ?? [:])
        if result.isError == true, value["error"] == nil {
            value["error"] = result.content.compactMap { if case .text(let text, _, _) = $0 { return text }; return nil }.first ?? "Submission failed"
        }
        return (try? correlatedSubmission(value, id: id, error: result.isError == true)) ?? result
    }

    private func submissionResult(_ queued: CallTool.Result) async -> CallTool.Result {
        guard let id = queued.structuredContent?.objectValue?["job_id"]?.stringValue else { return queued }
        // Creation normally takes milliseconds. Return its stable session identity when
        // available, but never hold a host request for downloads or content admission.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if let result = jobs[id], result.isError == true || result.structuredContent?.objectValue?["session_id"] != nil { return result }
            if Task.isCancelled { return jobs[id] ?? queued }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return jobs[id] ?? queued
    }
    private func form(_ name: String, _ args: [String: Any]) async throws -> CallTool.Result {
        guard let server else { throw MCPDocumentError("disconnected", "MCP connection ended") }
        guard supportsForm else { return try Self.result(["outcome": "form_unavailable", "fallback": "ui", "message": "This host does not advertise native OpenAI forms. Use the panel controls."]) }
        guard !formActive else { throw MCPDocumentError("form_busy", "A form is already open on this connection") }
        formActive = true; defer { formActive = false }
        let stringSchema = Self.field("string")
        var properties: [String: Value], required: [String], message: String
        switch name {
        case "transcription.start_form":
            let options: [Value] = assets.filter { $0.value.state == "ready" }.map { id, asset in
                .object(["uri": .string("voxstudio://inputs/\(id.uuidString)"), "name": .string(asset.name)])
            }
            var media: [String: Value] = ["type": "string", "format": "uri", "title": "Media", "x-openai-input": .object(["type": "resource", "options": .array(options), "userOptions": .object(["kind": "file", "accept": .array(Self.mediaExtensions.map { .string("." + $0) })])])]
            if let id = args["asset_id"] as? String { let selected = try assetID(args); guard assets[selected]?.state == "ready" else { throw MCPDocumentError("input_not_ready", "Wait for media import before opening the form") }; media["default"] = .string("voxstudio://inputs/\(id)") }
            properties = ["media": .object(media), "title": stringSchema, "language": .object(["type": "string", "title": "Source language (auto, zh, en, ja…)", "default": "auto"]), "model": .object(["type": "string", "title": "Configured language-aware model routing", "enum": ["automatic"], "default": "automatic"]), "speakers": .object(["type": "string", "enum": ["off", "auto", "one", "two", "three", "four"], "default": "auto"]), "segment_subtitles": .object(["type": "boolean", "default": false]), "target_languages": .object(["type": "array", "items": .object(["type": "string", "enum": ["en", "ja", "zh", "ko", "fr", "de", "es", "it", "pt"]]), "default": .array([])])]
            required = ["media", "model", "language", "speakers", "segment_subtitles", "target_languages"]
            message = "Choose media and transcription options. Submit to start; cancel creates no task."
        case "transcription.translate_form":
            _ = try sessionID(string(args, "session_id"))
            properties = ["target_languages": .object(["type": "array", "items": .object(["type": "string", "x-openai-suggestions": .array([.object(["const": "en", "title": "English"]), .object(["const": "ja", "title": "Japanese"]), .object(["const": "zh", "title": "Chinese"])])]), "minItems": 1, "maxItems": 10])]
            required = ["target_languages"]; message = "Choose translation language codes"
        default:
            _ = try sessionID(string(args, "session_id"))
            properties = ["format": .object(["type": "string", "enum": ["srt", "vtt", "txt", "md", "json"], "default": "srt"]), "language": .object(["type": "string", "default": .string(args["language"] as? String ?? "source")]), "name": .object(["type": "string", "default": "subtitles.srt"]), "bilingual": .object(["type": "boolean", "default": false])]
            required = ["format", "language", "name", "bilingual"]; message = "Choose export format and language"
        }
        let request = OpenAICreateElicitation.request(.init(message: message, mode: .form, requestedSchema: .init(properties: properties, required: required)))
        let response: OpenAICreateElicitation.Result
        do {
            let context = try await server.sendRequest(request, timeout: .seconds(45))
            response = try await context.value
        } catch is CancellationError { return try Self.result(["outcome": "cancelled"]) }
        catch {
            let timeout = error.localizedDescription.localizedCaseInsensitiveContains("timed out")
            return try Self.result(["outcome": timeout ? "timed_out" : "form_unavailable", "error": error.localizedDescription, "fallback": "ui"], error: timeout)
        }
        guard response.action == .accept else { return try Self.result(["outcome": response.action.rawValue]) }
        try Task.checkCancellation()
        let content = response.content ?? [:]
        guard Set(content.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ content[$0] != nil }) else { throw MCPDocumentError("invalid_form", "Form response has missing or unknown fields") }
        for (key, value) in content {
            let type = properties[key]?.objectValue?["type"]?.stringValue
            guard (type == "string" && value.stringValue != nil) || (type == "boolean" && value.boolValue != nil) || (type == "array" && value.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true) else { throw MCPDocumentError("invalid_form", "Invalid type for \(key)") }
            if let choices = properties[key]?.objectValue?["enum"]?.arrayValue, !choices.contains(value) { throw MCPDocumentError("invalid_form", "Unsupported \(key)") }
        }
        var options = ToolArgsBridge.argsFromMCP(content)
        if name == "transcription.start_form" {
            let uri = try string(options, "media")
            let id: UUID
            if uri.hasPrefix("voxstudio://inputs/"), let candidate = UUID(uuidString: String(uri.dropFirst("voxstudio://inputs/".count))), assets[candidate] != nil { id = candidate }
            else if let url = URL(string: uri), url.isFileURL {
                let bound = try await bindMedia(url)
                guard let candidate = bound.structuredContent?.objectValue?["asset_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw MCPDocumentError("invalid_media", "Could not bind selected media") }
                id = candidate
            } else { throw MCPDocumentError("unsupported_resource", "Use a local file or an input already selected in the panel") }
            options.removeValue(forKey: "media"); options.removeValue(forKey: "model")
            if options["language"] as? String == "auto" { options.removeValue(forKey: "language") }
            options["path"] = assets[id]!.url.path
            try MCPMediaTools.validate(options, name: "transcription.create")
            options.removeValue(forKey: "path")
            return try enqueueTranscription(id, options: options)
        }
        if name == "transcription.translate_form" {
            options["session_id"] = args["session_id"]
            try MCPMediaTools.validate(options, name: "transcription.translate")
            return try enqueueMedia("transcription.translate", options)
        }
        options["session_id"] = args["session_id"]; options["scope"] = args["scope"]
        return try await exportDocument(options)
    }

    private func editorTrack(_ args: [String: Any], readOnly: Bool = false) throws -> (UUID, String, String?, SubtitleTrack) {
        let id = try sessionID(string(args, "session_id"))
        if readOnly, let session = visibleSessions().first(where: { $0.id == id }) {
            let scope = args["scope"] as? String ?? "source", language = args["language"] as? String
            return (id, scope, language, try Self.readableTrack(session, scope: scope, language: language))
        }
        guard let job = WorkbenchStore.shared.transcriptions.first(where: { $0.id == id }), job.state == .completed,
              !WorkbenchStore.shared.hasActiveMediaFlow(id) else { throw MCPDocumentError("not_ready", "A local completed transcription is required for editing") }
        let scope = args["scope"] as? String ?? "source", language = args["language"] as? String
        let track: SubtitleTrack?
        switch scope {
        case "transcript": track = job.result.map(SubtitleTrack.fromTranscript)
        case "source": track = job.subtitleTrack
        case "translation":
            guard let language, let translation = job.translationTracks.first(where: { $0.languageCode == language }) else { throw MCPDocumentError("not_found", "Choose an existing translation language") }
            track = translation.track
        default: throw MCPDocumentError("invalid_argument", "scope must be transcript, source or translation")
        }
        guard let track else { throw MCPDocumentError("not_ready", "Track has no cues") }
        return (id, scope, language, track)
    }
    private func publicCues(_ track: SubtitleTrack) -> [MCPDocumentCue] {
        track.cues.map { .init(id: $0.id, start_ms: Int(($0.start * 1000).rounded()), end_ms: Int(($0.end * 1000).rounded()), text: $0.text, speaker: $0.speaker) }
    }
    private func revision(_ track: SubtitleTrack) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return MCPDocumentCodec.revision(try encoder.encode(publicCues(track)))
    }
    private func editorResult(_ args: [String: Any]) throws -> CallTool.Result {
        let (id, scope, language, track) = try editorTrack(args, readOnly: true)
        let cues = try JSONSerialization.jsonObject(with: JSONEncoder().encode(publicCues(track)))
        var value: [String: Any] = ["session_id": id.uuidString, "scope": scope, "revision": try revision(track), "cues": cues]
        value["language"] = language ?? track.language ?? "und"
        value["available"] = !track.cues.isEmpty
        value["editable"] = !track.cues.isEmpty && WorkbenchStore.shared.transcriptions.contains {
            $0.id == id && $0.state == .completed && !WorkbenchStore.shared.hasActiveMediaFlow(id)
        }
        let session = visibleSessions().first { $0.id == id }
        let sourceText = scope == "transcript" ? session.flatMap(KnowledgeTranscriptMaterial.from)?.text : nil
        value["paragraphs"] = SessionTranscriptParagraph.group(track.cues).map { paragraph in
            ["id": paragraph.id, "start_ms": Int((paragraph.start * 1000).rounded()),
             "end_ms": Int((paragraph.end * 1000).rounded()), "speaker": paragraph.speaker ?? "",
             "text": SessionTranscriptParagraph.text(paragraph.cues, language: track.language, sourceText: sourceText),
             "cue_ids": paragraph.cues.map(\.id)] as [String: Any]
        }
        return try Self.result(value)
    }
    private func commitSession(_ name: String, _ args: [String: Any]) async throws -> CallTool.Result {
        let requestID = try string(args, "request_id"), expected = try string(args, "expected_revision")
        let encoded = try JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
        let hash = MCPDocumentCodec.revision(encoded)
        if let receipt = receipts[requestID] {
            guard receipt.0 == hash else { throw MCPDocumentError("request_id_reused", "request_id was reused with different arguments") }
            return receipt.1
        }
        var imported: [MCPDocumentCue]?
        if name == "session.document.apply" {
            let document = try await readDocument(args)
            guard document.revision == (try string(args, "document_revision")) else { throw MCPDocumentError("conflict", "Document changed; reload") }
            imported = try MCPDocumentCodec.cues(MCPDocumentCodec.decode(document.bytes).text, format: document.format)
        }
        // Check the current projection after all awaited reads, immediately before the single mutation.
        let (id, scope, language, initial) = try editorTrack(args)
        guard try revision(initial) == expected else { throw MCPDocumentError("conflict", "Session track changed; reload before applying") }
        var next = initial
        if let imported {
            next.cues = imported.enumerated().map { i, cue in .init(id: i+1, sourceIDs: [], text: cue.text, start: Double(cue.start_ms)/1000, end: Double(cue.end_ms)/1000, speaker: cue.speaker) }
        } else {
            guard let operations = args["operations"] as? [[String: Any]], !operations.isEmpty, operations.count <= 1000 else { throw MCPDocumentError("invalid_argument", "Provide 1–1000 editing operations") }
            for operation in operations {
                guard let cueID = (operation["cue_id"] as? NSNumber)?.intValue, let index = next.cues.firstIndex(where: { $0.id == cueID }) else { throw MCPDocumentError("invalid_cue", "Cue not found") }
                switch try string(operation, "type") {
                case "text":
                    let text = try string(operation, "text"); next.cues[index].text = text
                case "timing":
                    guard let start = (operation["start_ms"] as? NSNumber)?.doubleValue, let end = (operation["end_ms"] as? NSNumber)?.doubleValue,
                          start.isFinite, end.isFinite, start >= 0, end > start, end < Double(Int.max / 2) else { throw MCPDocumentError("invalid_timing", "Require end > start >= 0") }
                    next.cues[index].start = start/1000; next.cues[index].end = end/1000
                case "speaker": next.cues[index].speaker = try string(operation, "speaker", allowEmpty: true)
                case "merge":
                    guard let updated = next.mergingDown(fromCueID: cueID) else { throw MCPDocumentError("invalid_edit", "Cannot merge this cue") }; next = updated
                case "split":
                    guard let updated = next.splittingCue(id: cueID, leftText: try string(operation, "left_text"), rightText: try string(operation, "right_text")) else { throw MCPDocumentError("invalid_edit", "Cannot split this cue") }; next = updated
                default: throw MCPDocumentError("invalid_edit", "Unknown edit type")
                }
            }
        }
        try MCPDocumentCodec.validateCues(publicCues(next))
        next.usesWordTimestamps = false
        WorkbenchStore.shared.updateTranscription(id, persist: false) { job in
            switch scope {
            case "transcript": job.result = next.asTranscriptionResult(preservingWords: [], asrEngine: job.result?.asrEngine); job.editedText = next.text
            case "source": job.subtitleTrack = next; job.editedText = next.text
            default:
                if let index = job.translationTracks.firstIndex(where: { $0.languageCode == language }) { job.translationTracks[index].track = next; job.translationTracks[index].createdAt = Date() }
            }
        }
        try await WorkbenchStore.shared.saveMCPChanges()
        if let job = WorkbenchStore.shared.transcriptions.first(where: { $0.id == id }) { SessionIndexCoordinator.shared.ingest(job) }
        let base = try editorResult(args)
        var structured = base.structuredContent?.objectValue ?? [:]
        structured["outcome"] = "local_committed"
        structured["cloud_state"] = .string(WorkbenchStore.shared.transcriptions.first(where: { $0.id == id })?.resolvedCloudSyncState.rawValue ?? "none")
        let bytes = try JSONEncoder().encode(Value.object(structured))
        let result = CallTool.Result(content: [.text(String(decoding: bytes, as: UTF8.self))], structuredContent: Optional.some(.object(structured)))
        if receipts.count >= 100 { receipts.removeAll() }; receipts[requestID] = (hash, result)
        return result
    }
    private func exportDocument(_ args: [String: Any]) async throws -> CallTool.Result {
        var choice = args
        if let language = args["language"] as? String, language != "source", args["scope"] == nil { choice["scope"] = "translation" }
        let (_, _, _, track) = try editorTrack(choice, readOnly: true)
        guard !track.cues.isEmpty else { throw MCPDocumentError("not_ready", "This track has not been generated") }
        var cues = publicCues(track)
        if args["bilingual"] as? Bool == true, choice["scope"] as? String == "translation" {
            var sourceArgs = choice; sourceArgs["scope"] = "source"
            let source = try editorTrack(sourceArgs, readOnly: true).3
            cues = cues.map { cue in
                var next = cue
                let originals = source.cues.filter { $0.end > Double(cue.start_ms)/1000 && $0.start < Double(cue.end_ms)/1000 }
                next.text = originals.map(\.text).joined(separator: "\n") + "\n" + cue.text
                return next
            }
        }
        let format = try string(args, "format").lowercased()
        let name = args["name"] as? String ?? "subtitles.\(format)"
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return try await createDocument(name: base + "." + format, bytes: MCPDocumentCodec.export(cues, format: format, language: track.language))
    }
    func registerPreview(_ result: CallTool.Result) throws -> CallTool.Result {
        guard var value = result.structuredContent?.objectValue, let path = value["audio_path"]?.stringValue else { return result }
        let url = URL(fileURLWithPath: path)
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 8 * 1024 * 1024 else { throw MCPDocumentError("too_large", "Preview exceeds 8 MiB") }
        let uri = "voxstudio://previews/\(UUID().uuidString)"
        previews[uri] = (url, "audio/mp4"); value["preview_resource_uri"] = .string(uri); value["mime_type"] = "audio/mp4"
        return .init(content: result.content, structuredContent: .object(value), isError: result.isError)
    }
    private func preview(_ url: URL, args: [String: Any], subtitles: SubtitleTrack? = nil) async throws -> CallTool.Result {
        let start = (args["start"] as? NSNumber)?.doubleValue ?? 0, duration = (args["duration"] as? NSNumber)?.doubleValue ?? 15
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 30 else { throw MCPDocumentError("invalid_timing", "Preview duration must be 0–30 seconds") }
        let asset = AVURLAsset(url: url), total = try await asset.load(.duration).seconds
        guard total.isFinite, start < total else { throw MCPDocumentError("invalid_timing", "Preview exceeds duration") }
        let video = try await asset.loadTracks(withMediaType: .video)
        let mime = video.isEmpty ? "audio/mp4" : "video/mp4"
        let root = AppSupportPaths.applicationSupport().appendingPathComponent("MCPPreviews")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent(UUID().uuidString + (video.isEmpty ? ".m4a" : ".mp4"))
        guard let exporter = AVAssetExportSession(asset: asset, presetName: video.isEmpty ? AVAssetExportPresetAppleM4A : AVAssetExportPresetMediumQuality) else { throw MCPDocumentError("preview_failed", "Cannot encode preview") }
        let end = min(total, start + duration)
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        try await exporter.export(to: output, as: video.isEmpty ? .m4a : .mp4)
        guard try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 8 * 1024 * 1024 else { try? FileManager.default.removeItem(at: output); throw MCPDocumentError("too_large", "Preview exceeds 8 MiB") }
        let uri = "voxstudio://previews/\(UUID().uuidString)"; previews[uri] = (output, mime)
        return try Self.result(["preview_resource_uri": uri, "mime_type": mime, "start": start, "end": end, "captions_ready": subtitles?.cues.isEmpty == false, "cues": (subtitles?.cues.filter { $0.end > start && $0.start < end } ?? []).map { ["id": $0.id, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] }])
    }
    func readResource(_ uri: String) async throws -> ReadResource.Result {
        let resourceURI = Self.legacyUIURIs[uri] ?? uri
        if let panel = Self.uiResources.first(where: { $0.uri == resourceURI }) {
            guard let url = Bundle.module.url(forResource: panel.file, withExtension: "html", subdirectory: "MCPApps") else { throw MCPDocumentError("missing_ui", "MCP panel is missing from this build") }
            return .init(contents: [.text(try String(contentsOf: url, encoding: .utf8), uri: uri, mimeType: "text/html;profile=mcp-app", _meta: .init(additionalFields: [
                // Embedded branding uses data: and MCP preview bytes use blob:.
                // Declare both for the host's image/media CSP; no remote origin is needed.
                "ui": .object(["csp": .object(["connectDomains": .array([]), "resourceDomains": ["data:", "blob:"]]), "prefersBorder": false]),
                "openai/ui": .object(["availableDisplayModes": ["inline", "fullscreen"], "preferredDisplayMode": "fullscreen"])
            ]))])
        }
        if let (url, mime) = previews[uri] {
            let data = try Data(contentsOf: url)
            guard data.count <= 8 * 1024 * 1024 else { throw MCPDocumentError("too_large", "Preview exceeds 8 MiB") }
            return .init(contents: [.binary(data, uri: uri, mimeType: mime)])
        }
        if uri.hasPrefix("voxstudio://documents/"), let id = UUID(uuidString: String(uri.dropFirst("voxstudio://documents/".count))), documents.contains(id) {
            let document = try await documentStore.read(id, owner: owner)
            return .init(contents: [.text(try MCPDocumentCodec.decode(document.bytes).text, uri: uri, mimeType: "text/plain")])
        }
        if uri.hasPrefix("voxstudio://sessions/"), let id = UUID(uuidString: String(uri.dropFirst("voxstudio://sessions/".count))) {
            _ = try sessionID(id.uuidString)
            let session = visibleSessions().first { $0.id == id }!
            let result = try Self.result(Self.sessionDetails(session))
            let bytes = try JSONEncoder().encode(result.structuredContent)
            return .init(contents: [.text(String(decoding: bytes, as: UTF8.self), uri: uri, mimeType: "application/json")])
        }
        throw MCPDocumentError("not_found", "Resource not granted or no longer available")
    }
}
