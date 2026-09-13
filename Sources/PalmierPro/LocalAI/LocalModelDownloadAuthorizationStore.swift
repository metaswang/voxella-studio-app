import Foundation

actor LocalModelDownloadAuthorizationStore {
    struct Record: Codable, Equatable, Sendable {
        let id: LocalModelID
        let revision: String
    }

    static let shared = LocalModelDownloadAuthorizationStore()

    private let fileURL: URL

    init(rootURL: URL? = nil) {
        let root = rootURL ?? AppSupportPaths.applicationSupport()
        fileURL = root
            .appendingPathComponent("ModelDownloads", isDirectory: true)
            .appendingPathComponent("authorized.json")
    }

    func records() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: fileURL))
    }

    func authorize(_ record: Record) throws {
        var current = try records()
        current.removeAll { $0.id == record.id }
        current.append(record)
        try write(current)
    }

    func revoke(_ id: LocalModelID) throws {
        var current = try records()
        current.removeAll { $0.id == id }
        try write(current)
    }

    func replace(with records: [Record]) throws {
        try write(records)
    }

    private func write(_ records: [Record]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records.sorted { $0.id.rawValue < $1.id.rawValue })
        try data.write(to: fileURL, options: .atomic)
    }
}
