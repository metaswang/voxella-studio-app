import Foundation

enum LocalModelChunkIO {
    enum TransferError: LocalizedError, Equatable {
        case http(Int, retryAfter: String?)
        case invalidResponse
        case unexpectedFullObject
        case rangeMismatch
        case expiredSignature
        case objectVersionChanged
        case decoding

        var errorDescription: String? {
            switch self {
            case .http(let status, _): "The download service returned an error (HTTP \(status))."
            case .invalidResponse: "The download service returned an unexpected response."
            case .unexpectedFullObject: "The download service returned a complete file instead of the requested range."
            case .rangeMismatch: "The downloaded range did not match the requested chunk."
            case .expiredSignature: "The download authorization expired."
            case .objectVersionChanged: "The remote model files changed during download."
            case .decoding: "The download could not be verified."
            }
        }

        var isRetryable: Bool {
            switch self {
            case .http(let status, _) where status == 429 || (500..<600).contains(status): true
            case .invalidResponse: true
            default: false
            }
        }

        var retryAfterHeader: String? {
            if case .http(_, let retryAfter) = self { return retryAfter }
            return nil
        }
    }

    static func chunkCount(size: Int64, chunkSize: Int64) -> Int {
        guard size > 0 else { return 1 }
        return Int((size + chunkSize - 1) / chunkSize)
    }

    static func chunkBounds(index: Int, size: Int64, chunkSize: Int64) -> (offset: Int64, length: Int64) {
        let offset = Int64(index) * chunkSize
        let length = min(chunkSize, max(size - offset, 0))
        return (offset, length)
    }

    static func validatedRangeBody(
        data: Data,
        response: HTTPURLResponse,
        expectedOffset: Int64,
        expectedLength: Int64,
        expectedTotal: Int64
    ) throws -> Data {
        if response.statusCode == 200 {
            if expectedOffset == 0, expectedLength == expectedTotal, data.count == expectedLength {
                return data
            }
            throw TransferError.unexpectedFullObject
        }
        guard response.statusCode == 206 else { throw TransferError.http(response.statusCode, retryAfter: response.retryAfterHeader) }
        guard data.count == expectedLength else { throw TransferError.rangeMismatch }
        let expected = "bytes \(expectedOffset)-\(expectedOffset + expectedLength - 1)/\(expectedTotal)"
        guard response.value(forHTTPHeaderField: "Content-Range") == expected else {
            throw TransferError.rangeMismatch
        }
        return data
    }

    static func validateChunkHeaders(_ response: HTTPURLResponse, chunk: Int, etag: String, total: Int64) throws {
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw TransferError.expiredSignature }
            if response.statusCode == 409 { throw TransferError.objectVersionChanged }
            throw TransferError.http(response.statusCode, retryAfter: response.retryAfterHeader)
        }
        guard response.value(forHTTPHeaderField: "ETag") == "\"\(etag)\"",
              response.value(forHTTPHeaderField: "X-Model-Chunk") == String(chunk),
              response.value(forHTTPHeaderField: "X-Model-Object-Size") == String(total) else {
            throw TransferError.rangeMismatch
        }
    }

    static func validateRangeHeaders(_ response: HTTPURLResponse, offset: Int64, length: Int64, total: Int64) throws {
        if response.statusCode == 200 {
            guard offset == 0, length == total else { throw TransferError.unexpectedFullObject }
            return
        }
        guard response.statusCode == 206 else {
            throw TransferError.http(response.statusCode, retryAfter: response.retryAfterHeader)
        }
        guard response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(offset + length - 1)/\(total)" else {
            throw TransferError.rangeMismatch
        }
    }

    static func retryDelay(attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .seconds(min(max(seconds, 0.2), 60))
        }
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...(base * 0.25))
        return .seconds(min(base + jitter, 60))
    }

    static func writeChunkFile(_ source: URL, to payload: URL, offset: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forUpdating: payload)
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(offset))
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: block)
        }
        try output.synchronize()
    }

    static func writeChunk(_ data: Data, to payload: URL, offset: Int64) throws {
        let handle = try FileHandle(forUpdating: payload)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(offset, 0)))
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

private extension HTTPURLResponse {
    var retryAfterHeader: String? { value(forHTTPHeaderField: "Retry-After") }
}
