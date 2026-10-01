import Foundation

/// Validates headers before accepting the body, then streams bounded buffers to disk.
enum LocalModelHTTPTransfer {
    static func download(
        request: URLRequest,
        session: URLSession,
        expectedBytes: Int64,
        validate: @escaping @Sendable (HTTPURLResponse) throws -> Void,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let delegate = ModelFileTransfer(limit: expectedBytes, validate: validate, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(request: request, configuration: session.configuration, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Delegate callbacks use one serial queue. The lock only coordinates start/cancel with that queue.
private final class ModelFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var temporary: URL?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?
    private let limit: Int64
    private let validate: @Sendable (HTTPURLResponse) throws -> Void
    private let progress: @Sendable (Int64) -> Void

    init(limit: Int64, validate: @escaping @Sendable (HTTPURLResponse) throws -> Void, progress: @escaping @Sendable (Int64) -> Void) {
        self.limit = limit
        self.validate = validate
        self.progress = progress
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw LocalModelChunkIO.TransferError.invalidResponse }
            try validate(http)
            guard limit >= 0, response.expectedContentLength < 0 || response.expectedContentLength == limit else {
                throw LocalModelChunkIO.TransferError.rangeMismatch
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxstudio-model-\(UUID().uuidString)")
            temporary = url
            try Data().write(to: url, options: .atomic)
            file = try FileHandle(forWritingTo: url)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard Int64(data.count) <= limit - received else { throw LocalModelChunkIO.TransferError.rangeMismatch }
            guard let file else { throw LocalModelChunkIO.TransferError.invalidResponse }
            try file.write(contentsOf: data)
            received += Int64(data.count)
            progress(received)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var resultError = failure ?? error
        if lock.withLock({ cancelled }) { resultError = CancellationError() }
        if resultError == nil && received != limit { resultError = LocalModelChunkIO.TransferError.rangeMismatch }
        do { try file?.close() } catch { if resultError == nil { resultError = error } }
        file = nil
        session.finishTasksAndInvalidate()
        let continuation = self.continuation
        self.continuation = nil
        lock.withLock { self.task = nil }
        if let resultError {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            continuation?.resume(throwing: resultError)
        } else if let temporary {
            continuation?.resume(returning: temporary)
        } else {
            continuation?.resume(throwing: LocalModelChunkIO.TransferError.invalidResponse)
        }
    }
}
