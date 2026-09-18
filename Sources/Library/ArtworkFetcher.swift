import Foundation

/// Fetches album artwork from the free, keyless **iTunes Search API** for tracks
/// with none embedded. Offline-first: only runs when the user asks (Settings →
/// Fetch Missing Artwork), never automatically, no account or credit card.
enum ArtworkFetcher {
    /// Raw downloaded image bytes for an album, or nil. The caller thumbnails it.
    static func fetchRaw(artist: String, album: String) async -> Data? {
        guard artist != "Unknown Artist", !artist.isEmpty,
              album != "Unknown Album", !album.isEmpty else { return nil }
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("GlassMusic/2.0 (local iOS music player)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let art100 = decoded.results.first?.artworkUrl100 else { return nil }
        // iTunes returns a 100px URL; swap the size token for a larger image.
        let hiRes = art100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let imgURL = URL(string: hiRes),
              let (imgData, iResp) = try? await URLSession.shared.data(from: imgURL),
              (iResp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return imgData
    }

    private struct SearchResponse: Decodable {
        let results: [Item]
        struct Item: Decodable { let artworkUrl100: String? }
    }
}
