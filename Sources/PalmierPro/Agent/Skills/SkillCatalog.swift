import Foundation

/// One entry in the published catalog.json. `sha` is a content hash of the SKILL.md
/// and is the version anchor: a changed sha means an update is available.
struct SkillCatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let category: String?
    let name: String
    let description: String
    let sha: String
    let path: String

    var skillCategory: SkillCategory {
        SkillCategory(category)
    }
}

struct SkillCategory: Hashable, Identifiable, Sendable {
    static let videoEditing = SkillCategory("video-editing")
    static let recording = SkillCategory("recording")
    static let transcription = SkillCategory("transcription")
    static let dubbing = SkillCategory("dubbing")
    static let knowledge = SkillCategory("knowledge")
    static let local = SkillCategory("local")

    let id: String

    init(_ id: String?) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "other"
    }

    var title: String {
        switch id {
        case Self.videoEditing.id: "Video Editing"
        case Self.recording.id: "Recording"
        case Self.transcription.id: "Transcription"
        case Self.dubbing.id: "Dubbing"
        case Self.knowledge.id: "Knowledge"
        case Self.local.id: "Local"
        default: id.split(separator: "-").map(\.capitalized).joined(separator: " ")
        }
    }

    var systemImage: String {
        switch id {
        case Self.videoEditing.id: "timeline.selection"
        case Self.recording.id: "record.circle"
        case Self.transcription.id: "text.bubble"
        case Self.dubbing.id: "waveform.and.person.filled"
        case Self.knowledge.id: "brain"
        case Self.local.id: "folder"
        default: "square.grid.2x2"
        }
    }

    var sortOrder: Int {
        switch id {
        case Self.recording.id: 0
        case Self.transcription.id: 1
        case Self.dubbing.id: 2
        case Self.videoEditing.id: 3
        case Self.knowledge.id: 4
        case Self.local.id: 5
        default: 6
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Fetches the community skill catalog from the VoxStudio Pro skills repository.
@Observable
@MainActor
final class SkillCatalog {
    static let shared = SkillCatalog()
    nonisolated static let defaultBase = "https://raw.githubusercontent.com/voxstudio-me/voxstudio-skills/main"

    /// Override the catalog source to test against a local clone.
    static var base: String {
        ProcessInfo.processInfo.environment["VOXSTUDIO_SKILLS_BASE"]
            ?? defaultBase
    }

    private(set) var entries: [SkillCatalogEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private static var cacheURL: URL {
        DiskCache.rootDirectory.appendingPathComponent("skills-catalog.json")
    }

    private init() { loadCache() }

    func entry(id: String) -> SkillCatalogEntry? { entries.first { $0.id == id } }

    static func bodyURL(path: String) -> URL? { URL(string: "\(base)/\(path)") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode([SkillCatalogEntry].self, from: data)
        else { return }
        entries = decoded
    }

    func refresh() async {
        guard !isLoading, let url = URL(string: "\(Self.base)/catalog.json") else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await Self.fetch(url)
            entries = try JSONDecoder().decode([SkillCatalogEntry].self, from: data)
            lastError = nil
            try? FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: Self.cacheURL)
            Log.agent.notice("skill catalog loaded \(self.entries.count) entries from \(Self.base)")
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("skill catalog refresh failed (\(Self.base)): \(error.localizedDescription)")
        }
    }

    /// Reads a catalog/body URL. File URLs are read directly
    static func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
