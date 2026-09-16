import Foundation

struct RecordingSessionManifest: Codable, Equatable, Sendable {
    var sessionID: String
    var startedAt: Date
    var outputPath: String
    var mode: String
    var backend: String
    var deviceID: String?
    var status: String

    static let inProgress = "inProgress"
    static let completed = "completed"
    static let failed = "failed"

    var manifestURL: URL {
        Self.manifestURL(for: URL(fileURLWithPath: outputPath))
    }

    static func manifestURL(for outputURL: URL) -> URL {
        outputURL.appendingPathExtension("recording.json")
    }

    static func uniqueOutputURL(directory: URL, capturesVideo: Bool, audioTrackCount: Int) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let ext: String
        if audioTrackCount >= 2 {
            ext = "mov"
        } else {
            ext = capturesVideo ? "mp4" : "m4a"
        }
        return directory.appendingPathComponent("Recording-\(stamp)-\(token).\(ext)")
    }

    static func write(_ manifest: RecordingSessionManifest) {
        let url = manifest.manifestURL
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.recording.warning("recording manifest write failed error=\(Log.detail(error))")
        }
    }

    static func remove(for outputURL: URL) {
        try? FileManager.default.removeItem(at: manifestURL(for: outputURL))
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return Int64(capacity)
        }
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map(Int64.init)
    }

    static func recoverInterruptedSessions(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var recovered: [URL] = []
        for manifestURL in contents where manifestURL.pathExtension == "json"
            && manifestURL.lastPathComponent.hasSuffix(".recording.json") {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data),
                  manifest.status == inProgress else {
                continue
            }
            let outputURL = URL(fileURLWithPath: manifest.outputPath)
            let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if FileManager.default.fileExists(atPath: outputURL.path), size > 0 {
                recovered.append(outputURL)
                Log.recording.notice(
                    "recording recovered interrupted session id=\(manifest.sessionID) path=\(outputURL.lastPathComponent) bytes=\(size)"
                )
            } else {
                Log.recording.warning(
                    "recording interrupted session has no media id=\(manifest.sessionID) path=\(outputURL.lastPathComponent)"
                )
            }
        }
        return recovered.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }
}
