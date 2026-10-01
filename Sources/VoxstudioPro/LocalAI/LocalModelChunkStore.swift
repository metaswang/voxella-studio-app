import Foundation

struct LocalModelChunkState: Codable, Equatable, Sendable {
    var repository: String
    var revision: String
    var path: String
    var etag: String
    var sizeBytes: Int64
    var chunkSizeBytes: Int64
    var completedChunks: [Int]
    var updatedAt: Date
    var cancelledAt: Date?
}

struct LocalModelChunkStore: Sendable {
    static let shared = LocalModelChunkStore()

    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = (rootURL ?? AppSupportPaths.applicationSupport())
            .appendingPathComponent("ModelDownloads", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    }

    func location(
        repository: String,
        revision: String,
        path: String,
        etag: String
    ) throws -> (directory: URL, payload: URL, state: URL) {
        let directory = try directoryURL(repository: repository, revision: revision, path: path, etag: etag)
        return (
            directory,
            directory.appendingPathComponent("payload", isDirectory: false),
            directory.appendingPathComponent("state.json", isDirectory: false)
        )
    }

    func load(
        repository: String,
        revision: String,
        path: String,
        etag: String,
        sizeBytes: Int64,
        chunkSizeBytes: Int64
    ) throws -> LocalModelChunkState {
        let urls = try location(repository: repository, revision: revision, path: path, etag: etag)
        if let existing = decodeState(at: urls.state),
           existing.repository == repository,
           existing.revision == revision,
           existing.path == path,
           existing.etag == etag,
           existing.sizeBytes == sizeBytes,
           existing.chunkSizeBytes == chunkSizeBytes {
            return existing.validated(against: urls.payload)
        }
        try FileManager.default.createDirectory(at: urls.directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: urls.payload.path) {
            try FileManager.default.removeItem(at: urls.payload)
        }
        try Data().write(to: urls.payload, options: .atomic)
        try truncate(urls.payload, to: sizeBytes)
        let state = LocalModelChunkState(
            repository: repository,
            revision: revision,
            path: path,
            etag: etag,
            sizeBytes: sizeBytes,
            chunkSizeBytes: chunkSizeBytes,
            completedChunks: [],
            updatedAt: Date(),
            cancelledAt: nil
        )
        try write(state, to: urls.state)
        return state
    }

    func markChunkComplete(_ chunk: Int, state: LocalModelChunkState) throws -> LocalModelChunkState {
        let urls = try location(
            repository: state.repository,
            revision: state.revision,
            path: state.path,
            etag: state.etag
        )
        try fsync(urls.payload)
        var next = state
        if !next.completedChunks.contains(chunk) {
            next.completedChunks.append(chunk)
            next.completedChunks.sort()
        }
        next.updatedAt = Date()
        next.cancelledAt = nil
        try write(next, to: urls.state)
        return next
    }

    func markCancelled(repository: String, revision: String) {
        updateCancelled(in: repositoryDirectory(repository: repository, revision: revision), cancelled: true)
    }

    func clearCancelled(repository: String, revision: String) {
        updateCancelled(in: repositoryDirectory(repository: repository, revision: revision), cancelled: false)
    }

    func remove(repository: String, revision: String) {
        try? FileManager.default.removeItem(at: repositoryDirectory(repository: repository, revision: revision))
    }

    func pruneExpired(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let owners = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for owner in owners {
            guard let revisions = try? fileManager.contentsOfDirectory(
                at: owner,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for revision in revisions {
                pruneExpired(in: revision, now: now)
            }
        }
    }

    private func pruneExpired(in directory: URL, now: Date) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent == "state.json" {
            guard let state = decodeState(at: url), let cancelledAt = state.cancelledAt else { continue }
            if now.timeIntervalSince(cancelledAt) >= LocalModelDownloadLimits.cancelledStagingRetention {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    private func updateCancelled(in directory: URL, cancelled: Bool) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent == "state.json" {
            guard var state = decodeState(at: url) else { continue }
            state.cancelledAt = cancelled ? Date() : nil
            state.updatedAt = Date()
            try? write(state, to: url)
        }
    }

    private func directoryURL(repository: String, revision: String, path: String, etag: String) throws -> URL {
        let encodedPath = path.split(separator: "/").joined(separator: "__")
        guard !encodedPath.isEmpty, !encodedPath.contains("..") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return repositoryDirectory(repository: repository, revision: revision)
            .appendingPathComponent(encodedPath, isDirectory: true)
            .appendingPathComponent(etag, isDirectory: true)
    }

    private func repositoryDirectory(repository: String, revision: String) -> URL {
        rootURL
            .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    private func decodeState(at url: URL) -> LocalModelChunkState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(LocalModelChunkState.self, from: data)
    }

    private func write(_ state: LocalModelChunkState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func truncate(_ url: URL, to size: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(max(size, 0)))
    }

    private func fsync(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

private extension LocalModelChunkState {
    func validated(against payload: URL) -> LocalModelChunkState {
        let fileSize = Int64((try? payload.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var next = self
        next.completedChunks = completedChunks.filter { chunk in
            let start = Int64(chunk) * chunkSizeBytes
            let length = min(chunkSizeBytes, max(sizeBytes - start, 0))
            return fileSize >= start + length
        }
        return next
    }
}
