import Foundation
import Observation

struct WorkbenchProjectSessionReference: Codable, Equatable, Sendable {
    var id: UUID
    var remoteSessionID: UUID?

    init(id: UUID, remoteSessionID: UUID? = nil) {
        self.id = id
        self.remoteSessionID = remoteSessionID
    }

    init(session: WorkbenchSession) {
        id = session.id
        remoteSessionID = session.remoteSessionID
    }

    func matches(_ session: WorkbenchSession) -> Bool {
        id == session.id || remoteSessionID == session.id
            || (remoteSessionID != nil && remoteSessionID == session.remoteSessionID)
    }
}

struct WorkbenchSessionProject: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var sessions: [WorkbenchProjectSessionReference] = []
}

/// Session folders are workspace metadata; removing a folder never removes media.
/// Membership keeps both local and Cloud identities without pruning unloaded sessions.
@Observable @MainActor
final class WorkbenchProjectsStore {
    static let shared = WorkbenchProjectsStore(
        fileURL: AppSupportPaths.applicationSupport().appendingPathComponent("session-projects.json")
    )

    private(set) var projects: [WorkbenchSessionProject] = []
    private(set) var loadError: String?
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            projects = try JSONDecoder().decode([WorkbenchSessionProject].self, from: Data(contentsOf: fileURL))
        } catch {
            loadError = error.localizedDescription
            Log.project.error("session project load failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func create(name: String, session: WorkbenchSession? = nil) throws -> UUID {
        let name = try normalizedName(name)
        let project = WorkbenchSessionProject(name: name, sessions: session.map { [WorkbenchProjectSessionReference(session: $0)] } ?? [])
        var updated = projects
        if let session {
            for index in updated.indices { updated[index].sessions.removeAll { $0.matches(session) } }
        }
        try commit(updated + [project])
        return project.id
    }

    func rename(_ id: UUID, name: String) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let name = try normalizedName(name)
        var updated = projects
        updated[index].name = name
        try commit(updated)
    }

    func remove(_ id: UUID) throws {
        try commit(projects.filter { $0.id != id })
    }

    func project(for session: WorkbenchSession) -> WorkbenchSessionProject? {
        projects.first { $0.sessions.contains { $0.matches(session) } }
    }

    func sessions(in project: WorkbenchSessionProject, from sessions: [WorkbenchSession]) -> [WorkbenchSession] {
        sessions.filter { session in project.sessions.contains { $0.matches(session) } }
    }

    func move(_ session: WorkbenchSession, to projectID: UUID?) throws {
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else { return }
        var updated = projects
        for index in updated.indices {
            updated[index].sessions.removeAll { $0.matches(session) }
            if updated[index].id == projectID {
                updated[index].sessions.append(WorkbenchProjectSessionReference(session: session))
            }
        }
        try commit(updated)
    }

    /// Register newly created jobs immediately, including empty voiceover drafts
    /// and remote meetings that have not appeared in the session catalog yet.
    func addNewSessions(_ ids: [UUID], to projectID: UUID, remoteOnly: Bool = false) throws {
        guard projects.contains(where: { $0.id == projectID }), !ids.isEmpty else { return }
        let ids = Set(ids)
        var updated = projects
        for index in updated.indices {
            updated[index].sessions.removeAll { ids.contains($0.id) || $0.remoteSessionID.map(ids.contains) == true }
            if updated[index].id == projectID {
                updated[index].sessions += ids.sorted { $0.uuidString < $1.uuidString }.map {
                    WorkbenchProjectSessionReference(id: $0, remoteSessionID: remoteOnly ? $0 : nil)
                }
            }
        }
        try commit(updated)
    }

    /// A local session may gain a Cloud ID after it is placed in a folder.
    func synchronizeIdentities(with sessions: [WorkbenchSession]) throws {
        var updated = projects
        for projectIndex in updated.indices {
            for index in updated[projectIndex].sessions.indices {
                let reference = updated[projectIndex].sessions[index]
                if let session = sessions.first(where: { reference.id == $0.id }),
                   let remoteID = session.remoteSessionID {
                    updated[projectIndex].sessions[index].remoteSessionID = remoteID
                }
            }
        }
        if updated != projects { try commit(updated) }
    }

    private func normalizedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectError.emptyName }
        return name
    }

    private func commit(_ updated: [WorkbenchSessionProject]) throws {
        guard loadError == nil else { throw ProjectError.unreadableStore }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        projects = updated
    }

    private enum ProjectError: LocalizedError {
        case emptyName, unreadableStore
        var errorDescription: String? {
            switch self {
            case .emptyName: "Enter a project name."
            case .unreadableStore: "Projects could not be loaded. The existing file was kept."
            }
        }
    }
}
