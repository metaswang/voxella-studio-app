import Foundation

enum YouTubeURL {
    static func videoID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isVideoID(trimmed) {
            return trimmed
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              isYouTubeHost(host) else {
            return nil
        }

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let id = url.path.split(separator: "/").first.map(String.init)
            return validatedID(id)
        }

        if let queryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value {
            return validatedID(queryID)
        }

        let parts = url.path.split(separator: "/").map(String.init)
        guard let markerIndex = parts.firstIndex(where: {
            ["embed", "shorts", "live", "v", "e"].contains($0.lowercased())
        }), parts.indices.contains(markerIndex + 1) else {
            return nil
        }
        return validatedID(parts[markerIndex + 1])
    }

    static func isSupported(_ raw: String) -> Bool {
        videoID(from: raw) != nil
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtu.be"
            || host.hasSuffix(".youtu.be")
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
    }

    private static func validatedID(_ value: String?) -> String? {
        guard let value, isVideoID(value) else { return nil }
        return value
    }

    private static func isVideoID(_ value: String) -> Bool {
        guard value.count == 11 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "a" && scalar <= "z")
                || scalar == "_"
                || scalar == "-"
        }
    }
}
