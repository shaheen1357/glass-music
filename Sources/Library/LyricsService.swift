import Foundation

struct LyricLine: Identifiable {
    let id = UUID()
    let time: Double        // seconds; 0-based
    let text: String        // "" == instrumental / gap marker
}

enum LyricsResult {
    case synced([LyricLine])
    case plain(String)
    case none
}

/// Resolves lyrics for a track: user .lrc sidecar → cached LRCLIB result →
/// LRCLIB network fetch → the plain lyrics embedded in the file's tags.
/// LRCLIB (lrclib.net) is a free, keyless, community lyrics DB built for local
/// players; results (including misses) are cached so we hit the network at most
/// once per track and the karaoke view works offline afterwards.
enum LyricsLoader {
    static func sidecarURL(for track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    static func resolve(for track: Track) async -> LyricsResult {
        // 1. A .lrc sidecar next to the file (user-provided, highest priority).
        if let content = try? String(contentsOf: sidecarURL(for: track), encoding: .utf8) {
            let lines = parse(content)
            if !lines.isEmpty { return .synced(lines) }
        }
        // 2. Cached LRCLIB result (respects a cached "miss" — no refetch).
        if let cached = cacheRead(track) {
            if let syn = cached.synced.map(parse), !syn.isEmpty { return .synced(syn) }
            if let p = cached.plain ?? nonEmpty(track.lyrics) { return .plain(p) }
        } else if let fetched = await fetchLRCLib(track) {
            // 3. Network fetch (only when we have no cache entry yet).
            cacheWrite(track, fetched)
            if let syn = fetched.synced.map(parse), !syn.isEmpty { return .synced(syn) }
            if let p = fetched.plain ?? nonEmpty(track.lyrics) { return .plain(p) }
        }
        // 4. Embedded lyrics from the file's tags (synced if LRC-timed, else plain).
        if let embedded = nonEmpty(track.lyrics) {
            let lines = parse(embedded)
            return lines.isEmpty ? .plain(embedded) : .synced(lines)
        }
        return .none
    }

    private static func nonEmpty(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }

    // MARK: - LRC parsing (multi-timestamp per line, [offset:], gap markers)
    static func parse(_ content: String) -> [LyricLine] {
        var offset = 0.0
        var lines: [LyricLine] = []
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var rest = String(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                if let t = time(from: tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000.0
                }
                rest = String(rest[rest.index(after: close)...])
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: max(0, t - offset), text: text)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func time(from tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]) else { return nil }
        let secParts = parts[1].split(separator: ".")
        guard let secFirst = secParts.first, let s = Double(secFirst) else { return nil }
        var frac = 0.0
        if secParts.count > 1, let f = Double("0." + secParts[1]) { frac = f }
        return m * 60 + s + frac
    }

    // MARK: - LRCLIB client
    struct Fetched { let synced: String?; let plain: String? }

    private struct LRCLibResponse: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
    }

    private static func fetchLRCLib(_ track: Track) async -> Fetched? {
        guard track.artist != "Unknown Artist", !track.artist.isEmpty, !track.title.isEmpty else { return nil }
        guard var comps = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("GlassMusic/1.0 (local iOS music player)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }   // network error: don't cache
        if http.statusCode == 404 { return Fetched(synced: nil, plain: nil) }   // definitive miss: cache it
        guard http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(LRCLibResponse.self, from: data) else { return nil }
        return Fetched(synced: decoded.syncedLyrics, plain: decoded.plainLyrics)
    }

    // MARK: - Cache (Application Support/Lyrics/<key>.json)
    private struct CacheEntry: Codable { let synced: String?; let plain: String? }

    private static var cacheDir: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheKey(_ track: Track) -> String {
        let raw = "\(track.artist)-\(track.title)-\(track.album)-\(Int(track.duration.rounded()))".lowercased()
        let safe = raw.map { ($0.isLetter || $0.isNumber) ? $0 : "_" }
        return String(String(safe).prefix(120))
    }

    private static func cacheRead(_ track: Track) -> CacheEntry? {
        let url = cacheDir.appendingPathComponent(cacheKey(track) + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private static func cacheWrite(_ track: Track, _ f: Fetched) {
        let url = cacheDir.appendingPathComponent(cacheKey(track) + ".json")
        if let data = try? JSONEncoder().encode(CacheEntry(synced: f.synced, plain: f.plain)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
