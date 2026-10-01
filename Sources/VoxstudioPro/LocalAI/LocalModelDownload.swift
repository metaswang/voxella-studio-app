import Foundation
#if BUNDLED_SPEECH
import HuggingFace
#endif

enum LocalModelDownload {
    #if BUNDLED_SPEECH
    private static let snapshotRefresh = SnapshotRefreshBox()

    struct SnapshotResponse: Decodable, Sendable {
        let files: [File]

        struct File: Decodable, Sendable {
            let path: String
            let url: URL
            let sizeBytes: Int64
            let etag: String?
            let download: ChunkDownload?

            enum CodingKeys: String, CodingKey {
                case path
                case url
                case sizeBytes = "size_bytes"
                case etag
                case download
            }
        }

        struct ChunkDownload: Decodable, Sendable {
            let version: Int
            let chunkSizeBytes: Int64
            let chunkURLTemplate: String
            let expiresAt: Int

            enum CodingKeys: String, CodingKey {
                case version
                case chunkSizeBytes = "chunk_size_bytes"
                case chunkURLTemplate = "chunk_url_template"
                case expiresAt = "expires_at"
            }

            var isSupported: Bool { version == 1 && chunkSizeBytes > 0 && chunkSizeBytes <= 32 * 1024 * 1024 && chunkURLTemplate.contains("{chunk}") }
        }
    }

    enum DownloadError: LocalizedError {
        case http(Int)
        case invalidResponse
        case invalidPath
        case decoding

        var errorDescription: String? {
            switch self {
            case .http(let status): "The download service returned an error (HTTP \(status))."
            case .invalidResponse: "The download service returned an unexpected response."
            case .invalidPath: "The downloaded files could not be prepared."
            case .decoding: "The download could not be verified."
            }
        }
    }

    @concurrent
    static func transferSnapshot(
        repository: Repo.ID,
        revision: String,
        to directory: URL,
        matching globs: [String],
        modelID: LocalModelID,
        estimatedBytes: Int64 = 0,
        session: URLSession = URLSession(configuration: .ephemeral),
        progressHandler: @escaping @MainActor @Sendable (LocalModelTransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        await progressHandler(
            LocalModelTransferProgress(completedBytes: 0, totalBytes: max(estimatedBytes, 1), bytesPerSecond: nil)
        )
        let snapshot = try await snapshotRefresh.snapshot(
            repository: repository.description,
            revision: revision,
            matching: globs,
            session: session
        )
        guard !snapshot.files.isEmpty else { throw DownloadError.invalidResponse }
        let files = try snapshot.files.map { file in
            (file: file, destination: try destinationURL(for: file.path, in: directory))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let totalBytes = max(files.reduce(Int64(0)) { $0 + max($1.file.sizeBytes, 0) }, 1)
        let completed = ProgressAccumulator(totalBytes: totalBytes, handler: progressHandler)
        await progressHandler(await completed.snapshot())

        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in files {
                group.addTask {
                    try await downloadResource(
                        item.file,
                        destination: item.destination,
                        repository: repository.description,
                        revision: revision,
                        matching: globs,
                        modelID: modelID,
                        session: session,
                        liveProgress: completed,
                        onBytes: { delta in
                            let progress = await completed.add(delta)
                            await progressHandler(progress)
                        }
                    )
                }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        await progressHandler(
            LocalModelTransferProgress(completedBytes: totalBytes, totalBytes: totalBytes, bytesPerSecond: nil)
        )
    }

    private static func downloadResource(
        _ file: SnapshotResponse.File,
        destination: URL,
        repository: String,
        revision: String,
        matching: [String],
        modelID: LocalModelID,
        session: URLSession,
        liveProgress: ProgressAccumulator,
        onBytes: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        if let download = file.download, download.isSupported, let etag = file.etag, !etag.isEmpty {
            try await downloadChunkedFile(
                file,
                destination: destination,
                repository: repository,
                revision: revision,
                matching: matching,
                modelID: modelID,
                session: session,
                liveProgress: liveProgress,
                onBytes: onBytes
            )
            return
        }
        var current = file
        var retries = 0
        var refreshes = 0
        while true {
            try Task.checkCancellation()
            let selected = current
            do {
                try await LocalModelDownloadScheduler.shared.withPermit(for: modelID) {
                    try await downloadWholeFile(from: selected.url, to: destination, expectedBytes: selected.sizeBytes,
                                                session: session, liveProgress: liveProgress, onBytes: onBytes)
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if case LocalModelChunkIO.TransferError.http(let status, _) = error,
                   status == 401 || status == 403 {
                    guard refreshes < 2 else { throw error }
                    refreshes += 1
                    try await Task.sleep(for: LocalModelChunkIO.retryDelay(attempt: refreshes, retryAfter: nil))
                    let snapshot = try await snapshotRefresh.snapshot(repository: repository, revision: revision,
                        matching: matching, session: session, force: true)
                    guard let refreshed = snapshot.files.first(where: { $0.path == file.path }),
                          refreshed.sizeBytes == file.sizeBytes, refreshed.etag == file.etag else {
                        throw LocalModelChunkIO.TransferError.objectVersionChanged
                    }
                    current = refreshed
                    continue
                }
                let transfer = error as? LocalModelChunkIO.TransferError
                let retryable = transfer?.isRetryable == true || (error as? URLError)?.isRetryableTransfer == true
                guard retryable, retries < LocalModelDownloadLimits.maximumTransferRetries else { throw error }
                retries += 1
                try await Task.sleep(for: LocalModelChunkIO.retryDelay(attempt: retries, retryAfter: transfer?.retryAfterHeader))
            }
        }
    }

    private static func downloadChunkedFile(
        _ initialFile: SnapshotResponse.File,
        destination: URL,
        repository: String,
        revision: String,
        matching: [String],
        modelID: LocalModelID,
        session: URLSession,
        liveProgress: ProgressAccumulator,
        onBytes: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        guard initialFile.download?.isSupported == true, let etag = initialFile.etag else {
            throw DownloadError.invalidResponse
        }
        let store = LocalModelChunkStore.shared
        let chunkSize = initialFile.download?.chunkSizeBytes ?? 0
        var state = try store.load(
            repository: repository,
            revision: revision,
            path: initialFile.path,
            etag: etag,
            sizeBytes: initialFile.sizeBytes,
            chunkSizeBytes: chunkSize
        )
        let urls = try store.location(repository: repository, revision: revision, path: initialFile.path, etag: etag)
        let restoredChunks = Set(state.completedChunks)
        if !restoredChunks.isEmpty {
            let restored = restoredChunks.reduce(Int64(0)) { partial, chunk in
                partial + LocalModelChunkIO.chunkBounds(index: chunk, size: initialFile.sizeBytes, chunkSize: chunkSize).length
            }
            await onBytes(restored)
        }

        let chunkCount = LocalModelChunkIO.chunkCount(size: initialFile.sizeBytes, chunkSize: chunkSize)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for chunk in 0..<chunkCount where !restoredChunks.contains(chunk) {
                group.addTask {
                    try await downloadChunk(
                        chunk,
                        initialFile: initialFile,
                        repository: repository,
                        revision: revision,
                        matching: matching,
                        payload: urls.payload,
                        modelID: modelID,
                        session: session,
                        liveProgress: liveProgress
                    )
                    return chunk
                }
            }
            for try await chunk in group {
                state = try store.markChunkComplete(chunk, state: state)
                let bounds = LocalModelChunkIO.chunkBounds(
                    index: chunk,
                    size: initialFile.sizeBytes,
                    chunkSize: chunkSize
                )
                await onBytes(bounds.length)
            }
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: urls.payload, to: destination)
        let actualBytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard actualBytes == initialFile.sizeBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func downloadChunk(
        _ chunk: Int,
        initialFile: SnapshotResponse.File,
        repository: String,
        revision: String,
        matching: [String],
        payload: URL,
        modelID: LocalModelID,
        session: URLSession,
        liveProgress: ProgressAccumulator
    ) async throws {
        let path = initialFile.path
        var refreshes = 0
        var usedDirectLink = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let file: SnapshotResponse.File
            if let current = await snapshotRefresh.file(path: path, repository: repository, revision: revision, matching: matching) {
                file = current
            } else {
                let snapshot = try await snapshotRefresh.snapshot(
                    repository: repository,
                    revision: revision,
                    matching: matching,
                    session: session
                )
                guard let resolved = snapshot.files.first(where: { $0.path == path }) else {
                    throw DownloadError.invalidResponse
                }
                file = resolved
            }
            guard let download = file.download, download.isSupported else {
                throw DownloadError.invalidResponse
            }
            guard file.etag == initialFile.etag, file.sizeBytes == initialFile.sizeBytes,
                  download.chunkSizeBytes == initialFile.download?.chunkSizeBytes else {
                throw LocalModelChunkIO.TransferError.objectVersionChanged
            }
            let bounds = LocalModelChunkIO.chunkBounds(index: chunk, size: file.sizeBytes, chunkSize: download.chunkSizeBytes)
            let fallbackToDirectLink = usedDirectLink
            do {
                try await LocalModelDownloadScheduler.shared.withPermit(for: modelID) {
                    if fallbackToDirectLink {
                        try await downloadDirectRange(
                            file.url,
                            to: payload,
                            offset: bounds.offset,
                            length: bounds.length,
                            total: file.sizeBytes,
                            session: session,
                            liveProgress: liveProgress
                        )
                    } else {
                        try await downloadCDNChunk(
                            template: download.chunkURLTemplate,
                            chunk: chunk,
                            to: payload,
                            offset: bounds.offset,
                            length: bounds.length,
                            etag: file.etag!,
                            total: file.sizeBytes,
                            session: session,
                            liveProgress: liveProgress
                        )
                    }
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LocalModelChunkIO.TransferError {
                switch error {
                case .expiredSignature, .objectVersionChanged, .http(401, _), .http(403, _):
                    guard refreshes < 2 else { throw error }
                    refreshes += 1
                    try await Task.sleep(for: LocalModelChunkIO.retryDelay(attempt: refreshes, retryAfter: nil))
                    _ = try await snapshotRefresh.snapshot(
                        repository: repository,
                        revision: revision,
                        matching: matching,
                        session: session,
                        force: true
                    )
                    continue
                default:
                    if error.isRetryable, attempt < LocalModelDownloadLimits.maximumTransferRetries {
                        attempt += 1
                        try await Task.sleep(for: LocalModelChunkIO.retryDelay(attempt: attempt, retryAfter: error.retryAfterHeader))
                        continue
                    }
                    if !usedDirectLink {
                        usedDirectLink = true
                        attempt = 0
                        continue
                    }
                    throw error
                }
            } catch let error as URLError where error.isRetryableTransfer {
                if attempt < LocalModelDownloadLimits.maximumTransferRetries {
                    attempt += 1
                    try await Task.sleep(for: LocalModelChunkIO.retryDelay(attempt: attempt, retryAfter: nil))
                    continue
                }
                if !usedDirectLink {
                    usedDirectLink = true
                    attempt = 0
                    continue
                }
                throw error
            }
        }
    }

    private static func downloadCDNChunk(
        template: String, chunk: Int, to payload: URL, offset: Int64, length: Int64,
        etag: String, total: Int64, session: URLSession, liveProgress: ProgressAccumulator
    ) async throws {
        guard let url = URL(string: template.replacingOccurrences(of: "{chunk}", with: String(chunk))) else {
            throw DownloadError.invalidResponse
        }
        let temporary = try await downloadTracked(request: URLRequest(url: url), session: session,
            expectedBytes: length, liveProgress: liveProgress) { http in
                try LocalModelChunkIO.validateChunkHeaders(http, chunk: chunk, etag: etag, total: total)
            }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try LocalModelChunkIO.writeChunkFile(temporary, to: payload, offset: offset)
    }

    private static func downloadDirectRange(
        _ url: URL, to payload: URL, offset: Int64, length: Int64, total: Int64,
        session: URLSession, liveProgress: ProgressAccumulator
    ) async throws {
        var request = URLRequest(url: url)
        if length > 0 { request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range") }
        let temporary = try await downloadTracked(request: request, session: session, expectedBytes: length,
            liveProgress: liveProgress) { http in
                try LocalModelChunkIO.validateRangeHeaders(http, offset: offset, length: length, total: total)
            }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try LocalModelChunkIO.writeChunkFile(temporary, to: payload, offset: offset)
    }

    private static func downloadWholeFile(
        from url: URL, to destination: URL, expectedBytes: Int64, session: URLSession,
        liveProgress: ProgressAccumulator, onBytes: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        let temporary = try await downloadTracked(request: URLRequest(url: url), session: session,
            expectedBytes: expectedBytes, liveProgress: liveProgress) { http in
                guard http.statusCode == 200 else {
                    throw LocalModelChunkIO.TransferError.http(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                }
            }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        await onBytes(expectedBytes)
    }

    private static func downloadTracked(
        request: URLRequest, session: URLSession, expectedBytes: Int64, liveProgress: ProgressAccumulator,
        validate: @escaping @Sendable (HTTPURLResponse) throws -> Void
    ) async throws -> URL {
        let id = await liveProgress.beginTransfer()
        do {
            let url = try await LocalModelHTTPTransfer.download(request: request, session: session,
                expectedBytes: expectedBytes, validate: validate) { bytes in
                    Task { await liveProgress.updateTransfer(id, bytes: bytes) }
                }
            await liveProgress.endTransfer(id)
            return url
        } catch {
            await liveProgress.endTransfer(id)
            throw error
        }
    }
    #endif

    static func destinationURL(for relativePath: String, in directory: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return components.reduce(directory) { current, component in
            current.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    static func message(for error: Error) -> String {
        #if BUNDLED_SPEECH
        if let error = error as? DownloadError {
            switch error {
            case .http(401), .http(403):
                return "The resource download was denied. Try again later."
            case .http(429):
                return "Too many download requests were made. Wait a few minutes, then retry."
            case .http:
                return "The resource download service is temporarily unavailable. Try again later."
            case .invalidResponse, .invalidPath, .decoding:
                return "The resource download could not be verified. Try again later."
            }
        }
        if let error = error as? LocalModelChunkIO.TransferError {
            switch error {
            case .http(401, _), .http(403, _), .expiredSignature:
                return "The resource download was denied. Try again later."
            case .http(429, _):
                return "Too many download requests were made. Wait a few minutes, then retry."
            case .unexpectedFullObject, .rangeMismatch, .objectVersionChanged, .decoding, .invalidResponse:
                return "The resource download could not be verified. Try again later."
            case .http:
                return "The resource download service is temporarily unavailable. Try again later."
            }
        }
        #endif
        if error is URLError {
            return "The resource download could not reach the service. Check your connection and retry."
        }
        if error is CocoaError {
            return "The resource could not be saved. Check disk space and permissions."
        }
        return "The resource download failed. Try again."
    }

    static func diagnostic(for error: Error) -> String {
        #if BUNDLED_SPEECH
        if let error = error as? DownloadError { return error.localizedDescription }
        if let error = error as? LocalModelChunkIO.TransferError { return error.localizedDescription }
        #endif
        // URL errors may contain signed download URLs in their description or userInfo.
        let nsError = error as NSError
        return "\(nsError.domain) code=\(nsError.code)"
    }
}

#if BUNDLED_SPEECH
private actor SnapshotRefreshBox {
    private var inflight: [SnapshotKey: Task<LocalModelDownload.SnapshotResponse, Error>] = [:]
    private var latest: [SnapshotKey: LocalModelDownload.SnapshotResponse] = [:]

    struct SnapshotKey: Hashable {
        var repository: String
        var revision: String
        var matching: [String]
    }

    func file(
        path: String,
        repository: String,
        revision: String,
        matching: [String]
    ) -> LocalModelDownload.SnapshotResponse.File? {
        let key = SnapshotKey(repository: repository, revision: revision, matching: matching)
        return latest[key]?.files.first { $0.path == path }
    }

    func snapshot(
        repository: String,
        revision: String,
        matching: [String],
        session: URLSession,
        force: Bool = false
    ) async throws -> LocalModelDownload.SnapshotResponse {
        let key = SnapshotKey(repository: repository, revision: revision, matching: matching)
        if let inflight = inflight[key] {
            return try await inflight.value
        }
        let task = Task {
            try await requestSnapshot(repository: repository, revision: revision, matching: matching, session: session)
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        let response = try await task.value
        latest[key] = response
        return response
    }
}

private func requestSnapshot(
    repository: String,
    revision: String,
    matching: [String],
    session: URLSession
) async throws -> LocalModelDownload.SnapshotResponse {
    struct Body: Encodable {
        let repository: String
        let revision: String
        let matching: [String]
    }

    var rateLimitRetry = 0
    while true {
        var request = URLRequest(url: VoxellaAPIConfiguration.apiURL("api/v1/studio-models/snapshot"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(repository: repository, revision: revision, matching: matching))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalModelDownload.DownloadError.invalidResponse }
        if http.statusCode == 429, rateLimitRetry < 1 {
            rateLimitRetry += 1
            try await Task.sleep(for: .seconds(min(15 * pow(2, Double(rateLimitRetry - 1)), 60)))
            continue
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalModelDownload.DownloadError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(LocalModelDownload.SnapshotResponse.self, from: data)
        } catch {
            throw LocalModelDownload.DownloadError.decoding
        }
    }
}

private actor ProgressAccumulator {
    private var completedBytes: Int64 = 0
    private let totalBytes: Int64
    private var samples: [(Date, Int64)] = []
    private var transfers: [UUID: Int64] = [:]
    private var lastEmission = Date.distantPast
    private let handler: @MainActor @Sendable (LocalModelTransferProgress) -> Void

    init(totalBytes: Int64, handler: @escaping @MainActor @Sendable (LocalModelTransferProgress) -> Void) {
        self.totalBytes = totalBytes
        self.handler = handler
    }

    func beginTransfer() -> UUID {
        let id = UUID()
        transfers[id] = 0
        return id
    }

    func updateTransfer(_ id: UUID, bytes: Int64) async {
        guard let previous = transfers[id] else { return }
        transfers[id] = max(previous, bytes)
        guard Date().timeIntervalSince(lastEmission) >= 0.2 else { return }
        lastEmission = Date()
        await handler(add(0))
    }

    func endTransfer(_ id: UUID) async {
        transfers[id] = nil
        await handler(add(0))
    }

    func add(_ delta: Int64) -> LocalModelTransferProgress {
        completedBytes = min(totalBytes, max(completedBytes + delta, 0))
        let now = Date()
        let displayed = min(totalBytes, completedBytes + transfers.values.reduce(0, +))
        if let last = samples.last, displayed < last.1 { samples.removeAll() }
        samples.append((now, displayed))
        samples.removeAll { now.timeIntervalSince($0.0) > 2 }
        let rate: Double?
        if let first = samples.first, now.timeIntervalSince(first.0) >= 0.2 {
            rate = Double(displayed - first.1) / now.timeIntervalSince(first.0)
        } else {
            rate = nil
        }
        return LocalModelTransferProgress(completedBytes: displayed, totalBytes: totalBytes, bytesPerSecond: rate)
    }

    func snapshot() -> LocalModelTransferProgress {
        LocalModelTransferProgress(completedBytes: completedBytes, totalBytes: totalBytes, bytesPerSecond: nil)
    }
}

private extension URLError {
    var isRetryableTransfer: Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
            true
        default:
            false
        }
    }
}
#endif
