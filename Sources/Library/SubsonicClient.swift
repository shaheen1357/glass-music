import Foundation
import CryptoKit

/// Credentials for a Subsonic-compatible server (Navidrome). Token auth: each
/// request sends a fresh random salt plus md5(password + salt), so the password
/// itself never crosses the wire.
struct SubsonicCredentials: Codable, Equatable, Sendable {
    var baseURL: URL          // e.g. http://140.245.229.48:4533
    var username: String
    var password: String
}

enum SubsonicError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int)
    case api(code: Int, message: String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No server configured."
        case .badURL:        return "The server address isn't valid."
        case .http(let c):   return "Server returned HTTP \(c)."
        case .api(_, let m): return m
        case .malformed:     return "Unexpected response from the server."
        }
    }
}

/// A thin Subsonic API client. Stateless apart from the credentials, so it's a
/// value type; every call builds a signed URL and decodes the JSON envelope.
struct SubsonicClient: Sendable {
    let credentials: SubsonicCredentials
    private let clientName = "glass-music"
    private let apiVersion = "1.16.1"

    // MARK: - Signed request building
    private func url(_ endpoint: String, _ items: [URLQueryItem] = []) throws -> URL {
        let endpointURL = credentials.baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("\(endpoint).view")
        guard var comps = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw SubsonicError.badURL
        }
        let salt = Self.randomSalt()
        let token = Self.md5Hex(credentials.password + salt)
        var query = [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
        query.append(contentsOf: items)
        comps.queryItems = (comps.queryItems ?? []) + query
        guard let u = comps.url else { throw SubsonicError.badURL }
        return u
    }

    /// Streaming URL (optionally asking the server to transcode down to save
    /// bandwidth). Carries auth in the query, so a downloader can GET it directly.
    func streamURL(id: String, maxBitRate: Int? = nil, format: String? = nil) -> URL? {
        var items = [URLQueryItem(name: "id", value: id)]
        if let maxBitRate { items.append(URLQueryItem(name: "maxBitRate", value: String(maxBitRate))) }
        if let format { items.append(URLQueryItem(name: "format", value: format)) }
        return try? url("stream", items)
    }

    /// Original file, no transcoding.
    func downloadURL(id: String) -> URL? {
        try? url("download", [URLQueryItem(name: "id", value: id)])
    }

    /// Cover-art image URL (optionally a specific pixel size).
    func coverArtURL(id: String, size: Int? = nil) -> URL? {
        var items = [URLQueryItem(name: "id", value: id)]
        if let size { items.append(URLQueryItem(name: "size", value: String(size))) }
        return try? url("getCoverArt", items)
    }

    // MARK: - Catalog
    func ping() async throws {
        let body = try await get(SubEnvelope<StatusBody>.self, "ping").response
        try check(body.status, body.error)
    }

    func artists() async throws -> [SubArtist] {
        let body = try await get(SubEnvelope<ArtistsBody>.self, "getArtists").response
        try check(body.status, body.error)
        return body.artists?.index?.flatMap { $0.artist ?? [] } ?? []
    }

    func albums(forArtist id: String) async throws -> [SubAlbum] {
        let body = try await get(SubEnvelope<ArtistBody>.self, "getArtist",
                                 [URLQueryItem(name: "id", value: id)]).response
        try check(body.status, body.error)
        return body.artist?.album ?? []
    }

    func songs(forAlbum id: String) async throws -> [SubChild] {
        let body = try await get(SubEnvelope<AlbumBody>.self, "getAlbum",
                                 [URLQueryItem(name: "id", value: id)]).response
        try check(body.status, body.error)
        return body.album?.song ?? []
    }

    func newestAlbums(size: Int = 100, offset: Int = 0) async throws -> [SubAlbum] {
        let items = [URLQueryItem(name: "type", value: "newest"),
                     URLQueryItem(name: "size", value: String(size)),
                     URLQueryItem(name: "offset", value: String(offset))]
        let body = try await get(SubEnvelope<AlbumList2Body>.self, "getAlbumList2", items).response
        try check(body.status, body.error)
        return body.albumList2?.album ?? []
    }

    func starredSongs() async throws -> [SubChild] {
        let body = try await get(SubEnvelope<StarredBody>.self, "getStarred2").response
        try check(body.status, body.error)
        return body.starred2?.song ?? []
    }

    func search(_ query: String) async throws -> SubSearchResult {
        let body = try await get(SubEnvelope<SearchBody>.self, "search3",
                                 [URLQueryItem(name: "query", value: query)]).response
        try check(body.status, body.error)
        return body.searchResult3 ?? SubSearchResult()
    }

    /// One page of the whole song catalog: OpenSubsonic's empty search3 query returns
    /// every song in natural order (Navidrome ≥ 0.53). One request per `size` songs —
    /// instead of one getAlbum per album, which is ~340 round trips on a singles library.
    func allSongs(size: Int = 500, offset: Int = 0) async throws -> [SubChild] {
        let items = [URLQueryItem(name: "query", value: "\"\""),
                     URLQueryItem(name: "artistCount", value: "0"),
                     URLQueryItem(name: "albumCount", value: "0"),
                     URLQueryItem(name: "songCount", value: String(size)),
                     URLQueryItem(name: "songOffset", value: String(offset))]
        let body = try await get(SubEnvelope<SearchBody>.self, "search3", items).response
        try check(body.status, body.error)
        return body.searchResult3?.song ?? []
    }

    func scrobble(id: String, submission: Bool = true) async throws {
        let items = [URLQueryItem(name: "id", value: id),
                     URLQueryItem(name: "submission", value: submission ? "true" : "false")]
        let body = try await get(SubEnvelope<StatusBody>.self, "scrobble", items).response
        try check(body.status, body.error)
    }

    func star(id: String, starred: Bool) async throws {
        let body = try await get(SubEnvelope<StatusBody>.self, starred ? "star" : "unstar",
                                 [URLQueryItem(name: "id", value: id)]).response
        try check(body.status, body.error)
    }

    // MARK: - Scan status (cheap change probe)
    /// The server's media-file count (and whether a scan is running). One tiny call —
    /// if the count hasn't moved since last time, the catalog hasn't changed and the
    /// client can skip walking it on open.
    func scanStatus() async throws -> (scanning: Bool, count: Int) {
        let body = try await get(SubEnvelope<ScanStatusBody>.self, "getScanStatus").response
        try check(body.status, body.error)
        return (body.scanStatus?.scanning ?? false, body.scanStatus?.count ?? 0)
    }

    // MARK: - Playlists (server-side, so they survive a reinstall)
    func serverPlaylists() async throws -> [SubPlaylist] {
        let body = try await get(SubEnvelope<PlaylistsBody>.self, "getPlaylists").response
        try check(body.status, body.error)
        return body.playlists?.playlist ?? []
    }

    func playlist(id: String) async throws -> (SubPlaylist, [SubChild]) {
        let body = try await get(SubEnvelope<PlaylistBody>.self, "getPlaylist",
                                 [URLQueryItem(name: "id", value: id)]).response
        try check(body.status, body.error)
        guard let p = body.playlist else { throw SubsonicError.malformed }
        return (SubPlaylist(id: p.id, name: p.name, songCount: p.entry?.count, owner: nil), p.entry ?? [])
    }

    /// Create a new server playlist, returning its server id.
    func createPlaylist(name: String, songIDs: [String]) async throws -> SubPlaylist? {
        var items = [URLQueryItem(name: "name", value: name)]
        items += songIDs.map { URLQueryItem(name: "songId", value: $0) }
        let body = try await get(SubEnvelope<PlaylistBody>.self, "createPlaylist", items).response
        try check(body.status, body.error)
        guard let p = body.playlist else { return nil }
        return SubPlaylist(id: p.id, name: p.name, songCount: p.entry?.count, owner: nil)
    }

    /// Replace an existing server playlist's songs (createPlaylist with a
    /// playlistId overwrites rather than creates — Subsonic's "set contents").
    func setPlaylist(id: String, songIDs: [String]) async throws {
        var items = [URLQueryItem(name: "playlistId", value: id)]
        items += songIDs.map { URLQueryItem(name: "songId", value: $0) }
        let body = try await get(SubEnvelope<StatusBody>.self, "createPlaylist", items).response
        try check(body.status, body.error)
    }

    func deletePlaylist(id: String) async throws {
        let body = try await get(SubEnvelope<StatusBody>.self, "deletePlaylist",
                                 [URLQueryItem(name: "id", value: id)]).response
        try check(body.status, body.error)
    }

    // MARK: - Transport
    private func get<T: Decodable>(_ type: T.Type, _ endpoint: String,
                                   _ items: [URLQueryItem] = []) async throws -> T {
        let u = try url(endpoint, items)
        let (data, resp) = try await URLSession.shared.data(from: u)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicError.http(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SubsonicError.malformed }
    }

    private func check(_ status: String?, _ error: SubApiError?) throws {
        if let error { throw SubsonicError.api(code: error.code, message: error.message ?? "Server error") }
        if status != "ok" { throw SubsonicError.malformed }
    }

    // MARK: - Crypto helpers
    private static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func randomSalt() -> String {
        let chars = Array("abcdef0123456789")
        return String((0..<12).map { _ in chars.randomElement()! })
    }
}

// MARK: - Response models (only the fields we use)
struct SubEnvelope<Body: Decodable>: Decodable {
    let response: Body
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}
struct SubApiError: Decodable { let code: Int; let message: String? }

struct StatusBody: Decodable { let status: String?; let error: SubApiError? }

struct ArtistsBody: Decodable {
    let status: String?; let error: SubApiError?
    let artists: SubArtistIndexes?
}
struct SubArtistIndexes: Decodable { let index: [SubArtistIndex]? }
struct SubArtistIndex: Decodable { let name: String?; let artist: [SubArtist]? }

struct SubArtist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let albumCount: Int?
    let coverArt: String?
}

struct ArtistBody: Decodable {
    let status: String?; let error: SubApiError?
    let artist: SubArtistDetail?
}
struct SubArtistDetail: Decodable { let id: String; let name: String?; let album: [SubAlbum]? }

struct SubAlbum: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let year: Int?
}

struct AlbumBody: Decodable {
    let status: String?; let error: SubApiError?
    let album: SubAlbumDetail?
}
struct SubAlbumDetail: Decodable {
    let id: String; let name: String?; let artist: String?; let coverArt: String?
    let song: [SubChild]?
}

struct AlbumList2Body: Decodable {
    let status: String?; let error: SubApiError?
    let albumList2: SubAlbumList2?
}
struct SubAlbumList2: Decodable { let album: [SubAlbum]? }

struct StarredBody: Decodable {
    let status: String?; let error: SubApiError?
    let starred2: SubStarred?
}
struct SubStarred: Decodable { let song: [SubChild]? }

struct SearchBody: Decodable {
    let status: String?; let error: SubApiError?
    let searchResult3: SubSearchResult?
}
struct SubSearchResult: Decodable {
    var artist: [SubArtist]? = nil
    var album: [SubAlbum]? = nil
    var song: [SubChild]? = nil
}

struct ScanStatusBody: Decodable {
    let status: String?; let error: SubApiError?
    let scanStatus: SubScanStatus?
}
struct SubScanStatus: Decodable { let scanning: Bool?; let count: Int? }

struct PlaylistsBody: Decodable {
    let status: String?; let error: SubApiError?
    let playlists: SubPlaylists?
}
struct SubPlaylists: Decodable { let playlist: [SubPlaylist]? }
struct SubPlaylist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let songCount: Int?
    let owner: String?
    var changed: String? = nil      // last-modified time; tells the cheap sync which lists moved
}
struct PlaylistBody: Decodable {
    let status: String?; let error: SubApiError?
    let playlist: SubPlaylistDetail?
}
struct SubPlaylistDetail: Decodable {
    let id: String; let name: String?; let entry: [SubChild]?
}

struct SubChild: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let album: String?
    let artist: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let duration: Int?
    let suffix: String?
    let contentType: String?
    let coverArt: String?
    let created: String?
    let albumId: String?
    let artistId: String?
    // Navidrome sends the real path only when the player has "Report Real Path" on
    // (absolute, e.g. "/music/aot/x.flac"); otherwise a fake relative one.
    let path: String?
}

// MARK: - Mapping to the app's Track + song identity
extension SubsonicClient {
    /// Map a Subsonic song to the app's Track. The id is namespaced with
    /// "subsonic:" so remote tracks are distinguishable from local (path-id) ones,
    /// and the url points at where the streamed file will be cached locally.
    func track(from c: SubChild) -> Track {
        let suffix = (c.suffix?.isEmpty == false) ? c.suffix! : "mp3"
        return Track(
            id: SubsonicID.prefix + c.id,
            url: SubsonicCache.fileURL(id: c.id, suffix: suffix),
            title: c.title ?? "Unknown",
            artist: c.artist ?? "Unknown Artist",
            album: c.album ?? "Unknown Album",
            albumArtist: nil,
            trackNumber: c.track ?? 0,
            discNumber: c.discNumber ?? 0,
            duration: Double(c.duration ?? 0),
            artworkData: nil,
            dateAdded: SubsonicID.parseDate(c.created),
            lyrics: nil,
            sourcePath: c.path
        )
    }
}

extension Track {
    /// Identity independent of where the audio is stored. Matches a local file to
    /// its server twin so a playlist survives the local file being deleted, and so
    /// the same song from two sources collapses into one.
    var contentKey: String {
        // Artist + album + title only. Track and disc numbers are deliberately excluded:
        // the local FLAC reader and Navidrome derive them differently from the same file
        // (Navidrome defaults disc to 1, a file with no disc tag reads as 0), so including
        // them made a song's local and server identities disagree and mis-pointed every
        // locally-held song to the server.
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return "\(norm(artist))\u{1}\(norm(album))\u{1}\(norm(title))"
    }

    /// A looser identity for deduping across sources when even the artist or album tag
    /// is read differently on each side: title plus duration in whole seconds, both of
    /// which come from the audio itself and agree for the same file. Truncated, not
    /// rounded: Navidrome sends int32(duration), so 466.89s arrives as 466 — rounding
    /// the local 466.89 to 467 missed every song whose fraction was .5 or more.
    var looseKey: String {
        "\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))\u{1}\(Int(duration))"
    }

    /// The audio file's name — the one identity both sides spell the same, whatever the
    /// tags say (Navidrome joins multiple artists as "A • B"; the local reader doesn't).
    /// Local: the file's own name. Remote: only from a real (absolute) server path; the
    /// fake relative path Navidrome reports by default says nothing about the file.
    var fileNameKey: String? {
        let name: String
        if SubsonicID.isRemote(self) {
            guard let p = sourcePath, p.hasPrefix("/") else { return nil }
            name = (p as NSString).lastPathComponent
        } else {
            name = url.lastPathComponent
        }
        return name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Finds the server copy of a local song: by file name first, then exact content key,
/// then the looser title+duration key. Pure (no store), so it is unit-testable.
struct RemoteIndex {
    private var byFileName: [String: Track] = [:]
    private var byContentKey: [String: Track] = [:]
    private var byLooseKey: [String: Track] = [:]

    init(_ remote: [Track] = []) {
        for r in remote {
            if let n = r.fileNameKey, byFileName[n] == nil { byFileName[n] = r }
            if byContentKey[r.contentKey] == nil { byContentKey[r.contentKey] = r }
            if byLooseKey[r.looseKey] == nil { byLooseKey[r.looseKey] = r }
        }
    }

    func twin(of track: Track) -> Track? {
        if let n = track.fileNameKey, let r = byFileName[n] { return r }
        return byContentKey[track.contentKey] ?? byLooseKey[track.looseKey]
    }

    func hasContentKey(_ key: String) -> Bool { byContentKey[key] != nil }

    /// True if the server has any song with this title — used to tell a song that
    /// failed to match apart from one that is genuinely phone-only.
    func hasTitle(_ title: String) -> Bool {
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return byLooseKey.keys.contains { $0.hasPrefix(t + "\u{1}") }
    }
}

enum SubsonicID {
    static let prefix = "subsonic:"
    static func isRemote(_ track: Track) -> Bool { track.id.hasPrefix(prefix) }
    static func serverID(for track: Track) -> String? {
        track.id.hasPrefix(prefix) ? String(track.id.dropFirst(prefix.count)) : nil
    }
    static func parseDate(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s) ?? .distantPast
    }
}

/// On-disk cache for streamed tracks. Cache-then-play keeps the crossfade/gapless
/// engine (which reads a local AVAudioFile) untouched, and gives offline reuse for
/// anything already heard.
/// Reports a download's fraction complete (0...1) as the bytes arrive, at most every
/// 2%, so the screen can draw it without redrawing on every packet. Navidrome sends a
/// length for unconverted files; without one the fraction stays at 0.
final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private var observation: NSKeyValueObservation?
    private var last = -1.0

    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            guard let self else { return }
            let f = p.fractionCompleted
            guard f - self.last >= 0.02 || f >= 1 else { return }
            self.last = f
            self.onProgress(f)
        }
    }
}

enum SubsonicCache {
    static var dir: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("StreamCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func fileURL(id: String, suffix: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).\(suffix)")
    }

    static func isCached(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Ensure a track's audio is on disk, downloading via the stream URL if not.
    /// Returns the local file URL for the engine to open.
    static func ensureCached(id: String, suffix: String, using client: SubsonicClient,
                             maxBitRate: Int? = nil, format: String? = nil,
                             onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        let dest = fileURL(id: id, suffix: suffix)
        if isCached(dest) { return dest }
        guard let remote = client.streamURL(id: id, maxBitRate: maxBitRate, format: format) else {
            throw SubsonicError.badURL
        }
        let (tmp, resp) = try await URLSession.shared.download(
            from: remote, delegate: onProgress.map(DownloadProgressDelegate.init))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw SubsonicError.http(http.statusCode)
        }
        // Never replace a copy that's already there: the player may have it open.
        // Moving into place is a single rename, so a reader sees no file or a whole one.
        if isCached(dest) {
            try? FileManager.default.removeItem(at: tmp)
            return dest
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Downloads you chose live here: Application Support, which iOS never purges
    /// (Caches it may empty when space runs low), and kept out of iCloud backup. The
    /// stream cache holds a link to each at the song's usual path, so everything that
    /// finds a song by that path (player, badges, offline filter) finds the download.
    static var downloadsDir: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Downloads", isDirectory: true)
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? d.setResourceValues(v)
        }
        return d
    }

    /// The file-name stem a server id is cached under (fileURL's naming).
    static func stem(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }

    /// Where the download of the song cached at `cacheURL` lives.
    static func downloadedFile(for cacheURL: URL) -> URL {
        downloadsDir.appendingPathComponent(cacheURL.lastPathComponent)
    }

    static func isDownloaded(_ cacheURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: downloadedFile(for: cacheURL).path)
    }

    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Point the song's cache path at its download. A plain cached copy already there
    /// gives way to the link; a player holding it open keeps reading it until done.
    static func link(_ cacheURL: URL) {
        let fm = FileManager.default
        let target = downloadedFile(for: cacheURL)
        guard fm.fileExists(atPath: target.path) else { return }
        if (try? fm.destinationOfSymbolicLink(atPath: cacheURL.path)) == target.path { return }
        try? fm.removeItem(at: cacheURL)
        try? fm.createSymbolicLink(at: cacheURL, withDestinationURL: target)
    }

    /// Delete a download and its link. A plain cached copy is left alone.
    static func removeDownload(_ cacheURL: URL) {
        let fm = FileManager.default
        if isLink(cacheURL) { try? fm.removeItem(at: cacheURL) }
        try? fm.removeItem(at: downloadedFile(for: cacheURL))
    }

    /// Bytes on disk: downloads, and the play cache (links to downloads not counted).
    static func sizes() -> (downloads: Int64, cache: Int64) {
        func total(_ dir: URL, skippingLinks: Bool) -> Int64 {
            let keys: [URLResourceKey] = [.fileSizeKey, .isSymbolicLinkKey]
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { return 0 }
            return items.reduce(0) { sum, u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                if skippingLinks && v?.isSymbolicLink == true { return sum }
                return sum + Int64(v?.fileSize ?? 0)
            }
        }
        return (total(downloadsDir, skippingLinks: false), total(dir, skippingLinks: true))
    }

    /// Empty the play cache. Downloads, and the links to them, stay.
    static func clear() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for u in items where !isLink(u) { try? FileManager.default.removeItem(at: u) }
    }
}
