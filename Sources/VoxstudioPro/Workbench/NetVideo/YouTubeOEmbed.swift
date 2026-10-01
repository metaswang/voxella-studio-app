import Foundation

struct YouTubeOEmbedMetadata: Decodable, Sendable {
    let title: String?
    let thumbnailURL: URL?

    enum CodingKeys: String, CodingKey {
        case title
        case thumbnailURL = "thumbnail_url"
    }
}

actor YouTubeOEmbedClient {
    static let shared = YouTubeOEmbedClient()
    private var cache: [String: YouTubeOEmbedMetadata?] = [:]

    func metadata(for sourceURL: URL) async -> YouTubeOEmbedMetadata? {
        let key = sourceURL.absoluteString
        if let cached = cache[key] { return cached }
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: key),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let endpoint = components?.url else {
            cache[key] = nil
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                cache[key] = nil
                return nil
            }
            let metadata = try JSONDecoder().decode(YouTubeOEmbedMetadata.self, from: data)
            cache[key] = metadata
            return metadata
        } catch {
            cache[key] = nil
            return nil
        }
    }
}
