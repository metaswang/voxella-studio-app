import AppKit
import AVFoundation
import Foundation
import MCP

/// Workbench operations deliberately do not depend on an editor project or MCP connection lifetime.
@MainActor
enum MCPMediaTools {
    nonisolated static let instructions = """

    Media tools work without a video project. transcription.create and dubbing.create return
    session_id immediately; poll media.status every few seconds until completed/failed/cancelled.
    transcription.translate adds language tracks without replacing the source; transcription.select_track
    chooses the visible subtitles. media.preview returns bounded timed cues and an audio preview file,
    and can open the session or play the clip in VoxStudio. voice.create needs an accurate transcript
    of the supplied reference clip (3–30 seconds of one speaker); never invent reference words.
    All creation uses local compute/storage. Models and translation/subtitle AI must be configured
    in VoxStudio. A failed operation is not a completed result; report its error before retrying.
    """

    nonisolated static let definitions: [KnowledgeToolDefinition] = [
        .init(name: "voice.list", description: "List available local reference voices and their IDs.", parameters: []),
        .init(name: "voice.create", description: "Create a reusable reference voice from a 3–30 second audio clip with its exact transcript.", parameters: [
            p("path", "string", "Absolute local audio path (or ~/ path)", true), p("name", "string", "Voice name", true),
            p("transcript", "string", "Exact spoken words in the clip", true), p("language", "string", "Language code", true),
            p("gender", "string", "female, male, or child; choose from user-provided metadata", true)]),
        .init(name: "voice.preview", description: "Return reference audio path and optionally play it in VoxStudio.", parameters: [
            p("voice_id", "string", "Reference UUID", true), p("play", "boolean", "Play in VoxStudio (default false)")]),
        .init(name: "dubbing.create", description: "Generate speech using a saved reference voice. Returns session_id for media.status and media.preview.", parameters: [
            p("text", "string", "Script to speak", true), p("voice_id", "string", "Reference UUID", true),
            p("language", "string", "Language code; defaults to reference language"), p("title", "string", "Session title")]),
        .init(name: "transcription.create", description: "Transcribe local audio/video, optionally segment subtitles and add multiple translated tracks. Returns session_id immediately.", parameters: [
            p("path", "string", "Absolute local media path (or ~/ path)", true), p("title", "string", "Session title"),
            p("language", "string", "Source language code; omit for auto detection"),
            p("speakers", "string", "off, auto, one, two, three, four (default auto)"),
            p("segment_subtitles", "boolean", "Use AI subtitle segmentation (default false; requires configured subtitle AI)"),
            p("target_languages", "array", "Translation language codes, e.g. [en, zh]; requires configured translation AI"),
            p("start", "number", "Optional clip start seconds; requires end"), p("end", "number", "Optional clip end seconds; requires start")]),
        .init(name: "transcription.translate", description: "Add one or more translated subtitle tracks to a completed transcription, preserving other languages.", parameters: [
            p("session_id", "string", "Transcription UUID", true), p("target_languages", "array", "Nonempty language codes", true)]),
        .init(name: "transcription.segment", description: "Prepare word-timed subtitle segments from a completed transcription using configured subtitle AI.", parameters: [p("session_id", "string", "Transcription UUID", true)]),
        .init(name: "transcription.select_track", description: "Choose source subtitles or an existing translated language in the session viewer.", parameters: [
            p("session_id", "string", "Transcription UUID", true), p("language", "string", "source or an existing translation language code", true)]),
        .init(name: "media.status", description: "Read a transcription/dubbing job's status, progress, errors and available language tracks.", parameters: [p("session_id", "string", "Session UUID", true)]),
        .init(name: "media.preview", description: "Preview transcription or dubbing: return timed cues and a bounded audio clip. Optional playback and session navigation.", parameters: [
            p("session_id", "string", "Session UUID", true), p("language", "string", "source or existing translation; defaults to selected track"),
            p("start", "number", "Start seconds (default 0)"), p("duration", "number", "Clip length in seconds, >0 to 30 (default 15)"),
            p("open", "boolean", "Open the session in VoxStudio (default false)"), p("play", "boolean", "Play the preview in VoxStudio (default false)")]),
    ]

    nonisolated private static func p(_ name: String, _ type: String, _ description: String, _ required: Bool = false) -> KnowledgeToolParameter {
        .init(name: name, type: type, description: description, required: required)
    }

    nonisolated static var tools: [Tool] {
        definitions.map { definition in
            let properties = Dictionary(uniqueKeysWithValues: definition.parameters.map { parameter in
                var value: [String: Value] = ["type": .string(parameter.type), "description": .string(parameter.description)]
                if parameter.type == "array" { value["items"] = .object(["type": "string"]) }
                return (parameter.name, Value.object(value))
            })
            return Tool(name: definition.name, description: definition.description, inputSchema: .object([
                "type": "object", "properties": .object(properties), "additionalProperties": false,
                "required": .array(definition.parameters.filter(\.required).map { .string($0.name) })]))
        }
    }

    private static var pipelines: [UUID: Task<Void, Never>] = [:]
    private static var pipelineErrors: [UUID: String] = [:]
    private static var player: AVAudioPlayer?

    static func validate(_ args: [String: Any], name: String) throws {
        guard let definition = definitions.first(where: { $0.name == name }) else { throw ToolError("Unknown media tool") }
        guard Set(args.keys).isSubset(of: Set(definition.parameters.map(\.name))) else { throw ToolError("Unknown argument") }
        try MCPKnowledgeTools.validate(args, definition: definition)
        for parameter in definition.parameters where parameter.type == "string" {
            if let value = args[parameter.name] as? String, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ToolError("\(parameter.name) must not be empty")
            }
        }
        if let id = args["voice_id"] as? String, UUID(uuidString: id) == nil { throw ToolError("Invalid voice UUID") }
        if let start = (args["start"] as? NSNumber)?.doubleValue, start < 0 { throw ToolError("start must be nonnegative") }
        if let duration = (args["duration"] as? NSNumber)?.doubleValue, duration <= 0 || duration > 30 { throw ToolError("duration must be >0 and <=30 seconds") }
        if name == "transcription.create", args["start"] != nil || args["end"] != nil {
            guard let start = (args["start"] as? NSNumber)?.doubleValue, let end = (args["end"] as? NSNumber)?.doubleValue, end > start,
                  end < Double(Int.max / 1000) else { throw ToolError("Clip requires start >=0 and end > start") }
        }
        if let languages = args["target_languages"] as? [String] {
            guard languages.count <= 10, Set(languages).count == languages.count,
                  languages.allSatisfy({ $0.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil }),
                  name != "transcription.translate" || !languages.isEmpty else { throw ToolError("Provide 1–10 unique translation language codes") }
        }
    }

    static func execute(name: String, args: [String: Any]) async -> ToolResult {
        do {
            try validate(args, name: name)
            let store = WorkbenchStore.shared
            let voices = VoiceLibraryStore.shared
            // These stores hydrate lazily. The first MCP call must allow their IO tasks to run.
            for _ in 0..<100 {
                if !store.isHydrating && !voices.isLoading { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !store.isHydrating, !voices.isLoading else { throw ToolError("Workbench is loading; retry shortly") }
            switch name {
            case "voice.list":
                return try json(["voices": VoiceLibraryStore.shared.references.map(voiceJSON)])
            case "voice.create":
                let url = try localFile(args["path"] as! String)
                guard let gender = VoiceReferenceGender(rawValue: args["gender"] as! String) else { throw ToolError("gender must be female, male, or child") }
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard duration.isFinite, (3...30).contains(duration) else { throw ToolError("Reference audio must be 3–30 seconds; trim a clip and provide its exact words") }
                let reference = try await VoiceLibraryStore.shared.create(.init(name: args["name"] as! String, languageCode: args["language"] as! String, gender: gender, transcript: args["transcript"] as! String, sourceAudioURL: url, avatarURL: nil))
                return try json(voiceJSON(reference))
            case "voice.preview":
                guard let voice = VoiceLibraryStore.shared.reference(id: UUID(uuidString: args["voice_id"] as! String)) else { throw ToolError("Voice not found") }
                if args["play"] as? Bool == true { VoiceLibraryStore.shared.stopPlayback(); VoiceLibraryStore.shared.togglePlayback(voice) }
                return try json(voiceJSON(voice))
            case "dubbing.create":
                guard let voice = VoiceLibraryStore.shared.reference(id: UUID(uuidString: args["voice_id"] as! String)) else { throw ToolError("Voice not found") }
                let language = args["language"] as? String ?? voice.languageCode
                guard WorkbenchDubLanguage(rawValue: language) != nil else { throw ToolError("Unsupported dubbing language") }
                try await AccountService.shared.prepareNewContentAccess()
                guard let id = store.addDub(script: args["text"] as! String, title: args["title"] as? String ?? "", openRoute: false) else { throw ToolError("Dubbing access unavailable") }
                store.updateDub(id) {
                    $0.language = language; $0.referenceVoiceID = voice.id; $0.placement = .localDefault
                    $0.speakerVoiceIDs = nil; $0.segmentVoiceIDs = nil
                    $0.referenceAudioPath = nil; $0.referenceText = ""
                }
                store.runDubAuthorized(id)
                return try status(id)
            case "transcription.create":
                let url = try localFile(args["path"] as! String)
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw ToolError("Media has no finite duration") }
                if let end = (args["end"] as? NSNumber)?.doubleValue, end > duration { throw ToolError("Clip end exceeds media duration") }
                let languages = args["target_languages"] as? [String] ?? []
                let segment = args["segment_subtitles"] as? Bool ?? false
                try await requireAI(segment: segment || !languages.isEmpty, translate: !languages.isEmpty)
                guard let speakers = SpeakerCountOption(rawValue: args["speakers"] as? String ?? "auto") else { throw ToolError("Invalid speakers option") }
                try await AccountService.shared.prepareNewContentAccess()
                var options = LocalProcessingOptions()
                options.languageCode = args["language"] as? String
                options.customTitle = args["title"] as? String
                options.speakerCount = speakers
                options.useLLMSubtitleProcessing = segment
                options.clipStartMs = ((args["start"] as? NSNumber)?.doubleValue).map { Int($0 * 1000) }
                options.clipEndMs = ((args["end"] as? NSNumber)?.doubleValue).map { Int($0 * 1000) }
                guard let batch = store.beginTranscriptions(sourceURLs: [url], options: options, openSessionWhenDone: false),
                      let id = store.transcriptions.first(where: { $0.batchID == batch })?.id else {
                    throw ToolError(store.transcriptionAdmissionError ?? "Transcription access unavailable")
                }
                if !languages.isEmpty { scheduleTranslations(id, languages: languages) }
                return try status(id)
            default:
                let id = UUID(uuidString: args["session_id"] as! String)!
                switch name {
                case "media.status": return try status(id)
                case "media.preview": return try await preview(id, args: args)
                case "transcription.select_track":
                    let job = try transcription(id)
                    let language = args["language"] as! String
                    _ = try track(job, language: language)
                    store.updateTranscription(id) {
                        $0.selectedTrack = language == "source" ? .source : .translation
                        if language != "source" { $0.selectedTranslationLanguageCode = language }
                    }
                    return try status(id)
                case "transcription.translate", "transcription.segment":
                    let job = try transcription(id)
                    guard job.state == .completed, !store.hasActiveMediaFlow(id), pipelines[id] == nil, job.result != nil else { throw ToolError("Wait for transcription and current operations to complete") }
                    try await requireAI(segment: true, translate: name == "transcription.translate")
                    try await AccountService.shared.prepareNewContentAccess()
                    pipelineErrors[id] = nil
                    if name == "transcription.translate" {
                        scheduleTranslations(id, languages: args["target_languages"] as! [String])
                    } else { store.prepareSubtitlesAuthorized(id) }
                    return try status(id)
                default: throw ToolError("Unknown media tool")
                }
            }
        } catch let error as ToolError { return .error(error.message) }
        catch { return .error(error.localizedDescription) }
    }

    private static func requireAI(segment: Bool, translate: Bool) async throws {
        _ = await LLMSettingsStore.shared.credentialAvailable()
        if segment && !LLMSettingsStore.shared.hasUsableModel(for: .subtitleProcessing) { throw ToolError("Configure subtitle processing in Settings → AI Service") }
        if translate && !LLMSettingsStore.shared.hasUsableModel(for: .translation) { throw ToolError("Configure translation in Settings → AI Service") }
    }

    private static func scheduleTranslations(_ id: UUID, languages: [String]) {
        pipelines[id] = Task {
            defer { pipelines[id] = nil }
            do {
                try await waitForTranscription(id)
                for language in languages {
                    try Task.checkCancellation()
                    WorkbenchStore.shared.updateTranscription(id) { $0.targetLanguageCode = language }
                    WorkbenchStore.shared.runTranslationAuthorized(id)
                    try await waitForTranscription(id)
                    guard try transcription(id).translationTracks.contains(where: { $0.languageCode == language }) else { throw ToolError("Translation did not produce \(language) subtitles") }
                }
            } catch let error as ToolError { pipelineErrors[id] = error.message }
            catch { pipelineErrors[id] = error.localizedDescription }
        }
    }

    private static func waitForTranscription(_ id: UUID) async throws {
        try await waitUntilReady {
            let job = try transcription(id)
            return (job.state, WorkbenchStore.shared.hasActiveMediaFlow(id), job.errorMessage)
        }
    }

    static func waitUntilReady(
        pollInterval: Duration = .milliseconds(300),
        snapshot: () throws -> (state: WorkbenchJobState, isBusy: Bool, error: String?)
    ) async throws {
        while true {
            try await Task.sleep(for: pollInterval)
            let value = try snapshot()
            if value.state == .completed && !value.isBusy { return }
            if value.state != .completed && !value.state.isActive {
                throw ToolError(value.error ?? "Operation ended: \(value.state.rawValue)")
            }
        }
    }

    private static func transcription(_ id: UUID) throws -> WorkbenchTranscriptionJob {
        guard let job = WorkbenchStore.shared.transcriptions.first(where: { $0.id == id }) else { throw ToolError("Transcription not found") }
        return job
    }

    private static func status(_ id: UUID) throws -> ToolResult {
        if let job = WorkbenchStore.shared.transcriptions.first(where: { $0.id == id }) {
            let finishing = job.state == .completed && WorkbenchStore.shared.hasActiveMediaFlow(id)
            var value: [String: Any] = ["session_id": id.uuidString, "kind": "transcription", "status": pipelineErrors[id] != nil ? "failed" : (pipelines[id] != nil || finishing ? "running" : job.state.rawValue), "progress": finishing ? min(job.progress, 0.99) : job.progress, "message": finishing ? "Finishing media processing" : job.progressMessage, "title": job.sessionTitle, "translation_languages": job.translationTracks.map(\.languageCode), "selected_track": job.currentTrack.rawValue]
            value["selected_language"] = selectedLanguage(job)
            value["error"] = pipelineErrors[id] ?? job.errorMessage
            return try json(value)
        }
        guard let job = WorkbenchStore.shared.dubs.first(where: { $0.id == id }) else { throw ToolError("Media session not found") }
        var value: [String: Any] = ["session_id": id.uuidString, "kind": "dubbing", "status": job.state.rawValue, "progress": job.progress, "message": job.progressMessage, "title": job.displayTitle]
        value["audio_path"] = job.outputURL?.path; value["error"] = job.errorMessage
        return try json(value)
    }

    static func selectedLanguage(_ job: WorkbenchTranscriptionJob) -> String {
        if job.currentTrack == .translation { return job.translationTrack?.language ?? "und" }
        return job.subtitleTrack?.language ?? job.result?.language ?? job.languageCode ?? "und"
    }

    static func track(_ job: WorkbenchTranscriptionJob, language: String?) throws -> SubtitleTrack? {
        let chosen = language ?? (job.currentTrack == .translation ? job.selectedTranslationLanguageCode : nil) ?? "source"
        if chosen == "source" { return job.subtitleTrack ?? job.result.map { SubtitleTrack.fromTranscript($0) } }
        guard let translation = job.translationTracks.first(where: { $0.languageCode.caseInsensitiveCompare(chosen) == .orderedSame }) else { throw ToolError("Translation track not found: \(chosen)") }
        return translation.track
    }

    private static func preview(_ id: UUID, args: [String: Any]) async throws -> ToolResult {
        let url: URL
        let subtitles: SubtitleTrack?
        if let job = WorkbenchStore.shared.transcriptions.first(where: { $0.id == id }) {
            guard job.result != nil else { throw ToolError("Transcript is not ready; poll media.status") }
            url = job.playbackAudioURL; subtitles = try track(job, language: args["language"] as? String)
        } else if let job = WorkbenchStore.shared.dubs.first(where: { $0.id == id }), let output = job.outputURL {
            if let language = args["language"] as? String, language != "source" { throw ToolError("Dubbing preview supports source track only") }
            url = output; subtitles = job.renderedSubtitleTrack
        } else { throw ToolError("Media result is not ready or session was not found") }
        let start = (args["start"] as? NSNumber)?.doubleValue ?? 0
        let duration = (args["duration"] as? NSNumber)?.doubleValue ?? 15
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard start < total else { throw ToolError("Preview start exceeds audio duration") }
        let end = min(total, start + duration)
        let directory = AppSupportPaths.applicationSupport().appendingPathComponent("MCPPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).m4a")
        if !FileManager.default.fileExists(atPath: output.path) {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw ToolError("Cannot export audio preview") }
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
            try await exporter.export(to: output, as: .m4a)
        }
        if args["open"] as? Bool == true {
            WorkbenchStore.shared.openSession(id); AppState.shared.showHome()
        }
        if args["play"] as? Bool == true {
            let next = try AVAudioPlayer(contentsOf: output)
            AudioPlaybackCoordinator.shared.begin(id: "mcp-preview") { player?.stop() }
            player = next; next.play()
        }
        let cues = subtitles?.cues.filter { $0.end > start && $0.start < end } ?? []
        return try json(["session_id": id.uuidString, "audio_path": output.path, "start": start, "end": end,
                         "language": subtitles?.language ?? "und", "cues": cues.map { ["id": $0.id, "start": $0.start, "end": $0.end, "text": $0.text, "speaker": $0.speaker ?? ""] as [String: Any] }])
    }

    private static func localFile(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ToolError("Use an absolute local file path") }
        let url = URL(fileURLWithPath: expanded)
        try LocalTranscriptionResourcePolicy.admit([url])
        return url
    }

    private static func voiceJSON(_ voice: LocalVoiceReference) -> [String: Any] {
        ["voice_id": voice.id.uuidString, "name": voice.name, "language": voice.languageCode, "duration": voice.duration,
         "transcript": voice.transcript, "audio_path": VoiceLibraryStore.shared.audioURL(for: voice).path]
    }

    private static func json(_ value: [String: Any]) throws -> ToolResult {
        .ok(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
}
