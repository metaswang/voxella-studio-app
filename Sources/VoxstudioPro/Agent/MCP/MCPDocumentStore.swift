import CryptoKit
import Foundation

struct MCPDocumentError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

struct MCPDocumentCue: Codable, Equatable, Sendable {
    var id: Int
    var start_ms: Int
    var end_ms: Int
    var text: String
    var speaker: String?
}

/// Raw text is the source of truth. Parsing never rewrites subtitle blocks or drops unsupported text.
enum MCPDocumentCodec {
    static let maxBytes = 2 * 1024 * 1024
    static let extensions = ["srt", "vtt", "txt", "md", "markdown", "json"]
    struct Decoded: Sendable { let text: String; let bom: Bool; let newline: String }
    struct Transcript: Codable { let schema: String; let schema_version: Int; let language: String?; let cues: [MCPDocumentCue] }

    static func decode(_ data: Data) throws -> Decoded {
        guard data.count <= maxBytes else { throw MCPDocumentError("too_large", "Text exceeds 2 MiB") }
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        let bytes = bom ? data.dropFirst(3) : data[...]
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
            throw MCPDocumentError("unsupported_encoding", "Use a UTF-8 text file")
        }
        return Decoded(text: text, bom: bom, newline: text.contains("\r\n") ? "\r\n" : "\n")
    }

    static func encode(_ text: String, original: Data) throws -> Data {
        let decoded = try decode(original)
        // Browser textareas normalize line endings. An unchanged edit must retain the exact bytes.
        if normalized(text) == normalized(decoded.text) { return original }
        var output = Data()
        if decoded.bom { output.append(contentsOf: [0xef, 0xbb, 0xbf]) }
        output.append(contentsOf: normalized(text).replacingOccurrences(of: "\n", with: decoded.newline).utf8)
        _ = try decode(output)
        return output
    }
    static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
    static func revision(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func validate(_ text: String, format: String) throws {
        switch format {
        case "srt", "vtt": _ = try cues(text, format: format)
        case "json": _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        default: break
        }
    }
    static func cues(_ text: String, format: String) throws -> [MCPDocumentCue] {
        if format == "json" {
            let value = try JSONDecoder().decode(Transcript.self, from: Data(text.utf8))
            guard value.schema == "voxstudio.transcript", value.schema_version == 1 else {
                throw MCPDocumentError("unsupported_schema", "Only voxstudio.transcript version 1 can be applied to a session")
            }
            try validateCues(value.cues)
            return value.cues
        }
        guard format == "srt" || format == "vtt" else { throw MCPDocumentError("unsupported_format", "Apply SRT, VTT or VoxStudio transcript JSON") }
        let lines = normalized(text).components(separatedBy: "\n")
        if format == "vtt", !(lines.first ?? "").hasPrefix("WEBVTT") { throw MCPDocumentError("invalid_subtitle", "Line 1: expected WEBVTT") }
        var blocks: [(Int, [String])] = [], current: [String] = [], first = 1
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { blocks.append((first, current)); current = [] }
            } else {
                if current.isEmpty { first = index + 1 }
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append((first, current)) }
        var result: [MCPDocumentCue] = []
        for (lineNumber, block) in blocks {
            let head = block[0]
            if format == "vtt", head.hasPrefix("WEBVTT") || head == "NOTE" || head.hasPrefix("NOTE ") || head == "STYLE" || head == "REGION" { continue }
            let timingIndex = head.contains("-->") ? 0 : 1
            guard block.count > timingIndex + 1, timingIndex < block.count else { throw MCPDocumentError("invalid_subtitle", "Line \(lineNumber): missing cue timing or text") }
            if format == "srt", timingIndex != 1 || Int(head) == nil { throw MCPDocumentError("invalid_subtitle", "Line \(lineNumber): expected SRT cue number") }
            let timing = block[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2, let start = timestamp(timing[0]), let end = timestamp(timing[1]), end > start else {
                throw MCPDocumentError("invalid_subtitle", "Line \(lineNumber + timingIndex): invalid cue timing")
            }
            result.append(.init(id: result.count + 1, start_ms: start, end_ms: end, text: block.dropFirst(timingIndex + 1).joined(separator: "\n"), speaker: nil))
        }
        guard !result.isEmpty else { throw MCPDocumentError("invalid_subtitle", "No subtitle cues found") }
        try validateCues(result)
        return result
    }
    private static func timestamp(_ value: String) -> Int? {
        let token = value.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!), seconds.isFinite, seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes) else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0, hours < 1_000_000 else { return nil }
        return Int((Double(hours * 3600 + minutes * 60) + seconds) * 1000 + 0.5)
    }
    static func validateCues(_ cues: [MCPDocumentCue]) throws {
        guard !cues.isEmpty, Set(cues.map(\.id)).count == cues.count,
              cues.allSatisfy({ $0.start_ms >= 0 && $0.end_ms > $0.start_ms && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MCPDocumentError("invalid_cues", "Cues require unique IDs, nonempty text and end > start >= 0")
        }
    }
    static func export(_ cues: [MCPDocumentCue], format: String, language: String?) throws -> Data {
        try validateCues(cues)
        if format == "json" { return try JSONEncoder().encode(Transcript(schema: "voxstudio.transcript", schema_version: 1, language: language, cues: cues)) }
        if format == "txt" || format == "md" || format == "markdown" { return Data(cues.map(\.text).joined(separator: "\n\n").utf8) }
        guard format == "srt" || format == "vtt" else { throw MCPDocumentError("unsupported_format", "Unsupported export format") }
        func time(_ ms: Int) -> String { String(format: "%02d:%02d:%02d%@%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, format == "srt" ? "," : ".", ms % 1000) }
        let body = cues.enumerated().map { i, cue in "\(i+1)\n\(time(cue.start_ms)) --> \(time(cue.end_ms))\n\(cue.text)" }.joined(separator: "\n\n")
        return Data(((format == "vtt" ? "WEBVTT\n\n" : "") + body + "\n").utf8)
    }
}

actor MCPDocumentStore {
    static let shared = MCPDocumentStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoxStudio/MCP/Documents"))
    struct Receipt: Codable, Sendable { let hash: String; let revision: String }
    struct Document: Codable, Sendable {
        let id: UUID; let name: String; let format: String; let owner: String?
        var bytes: Data
        var receipts: [String: Receipt] = [:]
        var revision: String { MCPDocumentCodec.revision(bytes) }
    }
    private let root: URL
    init(root: URL) { self.root = root }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    func list(owner: String?) throws -> [Document] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.compactMap { path in
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: path))
            return document.owner == nil || document.owner == owner ? document : nil
        }.sorted { $0.name < $1.name }
    }
    func read(_ id: UUID, owner: String?) throws -> Document {
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url(id)))
        guard document.owner == nil || document.owner == owner else { throw MCPDocumentError("not_found", "Document not visible") }
        return document
    }
    func create(name: String, bytes: Data, owner: String?) throws -> Document {
        _ = try MCPDocumentCodec.decode(bytes)
        let name = URL(fileURLWithPath: name).lastPathComponent
        let format = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard MCPDocumentCodec.extensions.contains(format) else { throw MCPDocumentError("unsupported_format", "Unsupported text extension") }
        let document = Document(id: UUID(), name: name, format: format, owner: owner, bytes: bytes)
        try save(document)
        return document
    }
    func commit(_ id: UUID, owner: String?, expected: String, text: String, requestID: String) throws -> Document {
        var document = try read(id, owner: owner)
        guard !requestID.isEmpty else { throw MCPDocumentError("invalid_request", "request_id is required") }
        let hash = MCPDocumentCodec.revision(Data((expected + "\0" + text).utf8))
        if let receipt = document.receipts[requestID] {
            guard receipt.hash == hash else { throw MCPDocumentError("request_id_reused", "request_id was reused with different content") }
            guard receipt.revision == document.revision else { throw MCPDocumentError("conflict", "Document changed after that saved request; reload") }
            return document
        }
        guard document.revision == expected else { throw MCPDocumentError("conflict", "Document changed; reload before saving") }
        let bytes = try MCPDocumentCodec.encode(text, original: document.bytes)
        try MCPDocumentCodec.validate(try MCPDocumentCodec.decode(bytes).text, format: document.format)
        document.bytes = bytes
        if document.receipts.count >= 100 { document.receipts.removeAll() }
        document.receipts[requestID] = Receipt(hash: hash, revision: document.revision)
        try save(document)
        return document
    }
    private func save(_ document: Document) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url(document.id), options: .atomic)
    }
}
