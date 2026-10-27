import Foundation
import Observation

/// Coordinates the Subsonic server with the local library: pulls the catalog and
/// playlists down (so a reinstall restores everything), pushes local playlist
/// edits back up, manages the offline download/cache, and resolves a track to a
/// playable local file for the engine. One @Observable owned by AppServices.
@MainActor
@Observable
final class SubsonicSync {
    enum State: Equatable { case idle, syncing, done, failed(String) }
    enum Availability { case local, downloaded, cached, streams }

    let store: SubsonicStore
    private unowned let library: LibraryStore
    private unowned let playlists: PlaylistStore

    private(set) var state: State = .idle
    private(set) var lastSynced: Date?

    // Explicitly downloaded (pinned) remote server-ids — never evicted.
    private(set) var pinnedIDs: Set<String> = []
    private let pinnedKey = "subsonic.pinned"

    init(store: SubsonicStore, library: LibraryStore, playlists: PlaylistStore) {
        self.store = store
        self.library = library
        self.playlists = playlists
        pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
    }

    var isConfigured: Bool { store.isConfigured }

    // MARK: - Pull (catalog + playlists + liked)
    func syncNow() async {
        guard let client = store.client else { return }
        state = .syncing
        do {
            try await syncCatalog(client)
            try await syncPlaylists(client)
            try await syncLiked(client)
            playlists.reconcileKeys(using: library)
            lastSynced = Date()
            state = .done
        } catch {
            state = .failed((error as? SubsonicError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func syncCatalog(_ client: SubsonicClient) async throws {
        // Walk artists → albums → songs. One cover thumbnail per album, shared by
        // its tracks, so a remote track carries artwork exactly like a local one.
        let artists = try await client.artists()
        var remote: [Track] = []
        for artist in artists {
            let albums = (try? await client.albums(forArtist: artist.id)) ?? []
            for album in albums {
                let songs = (try? await client.songs(forAlbum: album.id)) ?? []
                var art: Data?
                if let coverID = album.coverArt, let url = client.coverArtURL(id: coverID, size: 600) {
                    art = await Self.fetchThumbnail(url)
                }
                for s in songs {
                    var t = client.track(from: s)
                    if t.artworkData == nil { t.artworkData = art }
                    remote.append(t)
                }
            }
        }
        library.mergeRemote(remote)
    }

    private func syncPlaylists(_ client: SubsonicClient) async throws {
        let lists = try await client.serverPlaylists()
        var resolved: [(serverID: String, name: String, trackIDs: [String])] = []
        for pl in lists {
            let (_, songs) = try await client.playlist(id: pl.id)
            resolved.append((serverID: pl.id,
                             name: pl.name ?? "Playlist",
                             trackIDs: songs.map { SubsonicID.prefix + $0.id }))
        }
        playlists.applyServerPlaylists(resolved)
    }

    private func syncLiked(_ client: SubsonicClient) async throws {
        let songs = try await client.starredSongs()
        playlists.mergeLikedFromServer(songs.map { SubsonicID.prefix + $0.id })
    }

    // MARK: - Push local user playlists to the server (call on background / sign-out)
    func pushPlaylists() async {
        guard let client = store.client else { return }
        for pl in playlists.playlists where pl.kind == .user {
            let songIDs: [String] = pl.trackIDs.compactMap { id in
                if id.hasPrefix(SubsonicID.prefix) { return String(id.dropFirst(SubsonicID.prefix.count)) }
                // Local id → map to its server twin by content so the server stores it.
                if let t = library.tracksByID[id], let twin = library.remoteTwin(of: t) {
                    return SubsonicID.serverID(for: twin)
                }
                return nil
            }
            guard !songIDs.isEmpty else { continue }
            do {
                if let sid = pl.serverID {
                    try await client.setPlaylist(id: sid, songIDs: songIDs)
                } else if let created = try await client.createPlaylist(name: pl.name, songIDs: songIDs) {
                    playlists.setServerID(created.id, forID: pl.id)
                }
            } catch { /* best-effort per playlist */ }
        }
    }

    // MARK: - Offline availability / downloads
    func availability(_ track: Track) -> Availability {
        if !SubsonicID.isRemote(track) { return .local }
        let cached = SubsonicCache.isCached(track.url)
        if let sid = SubsonicID.serverID(for: track), pinnedIDs.contains(sid) {
            return cached ? .downloaded : .streams
        }
        return cached ? .cached : .streams
    }

    func isOnDevice(_ track: Track) -> Bool {
        SubsonicID.isRemote(track) ? SubsonicCache.isCached(track.url)
                                   : FileManager.default.fileExists(atPath: track.url.path)
    }

    @discardableResult
    func download(_ track: Track) async -> Bool {
        guard SubsonicID.isRemote(track), let sid = SubsonicID.serverID(for: track) else { return false }
        pinnedIDs.insert(sid); savePinned()
        _ = await ensureLocal(track)
        return SubsonicCache.isCached(track.url)
    }

    func download(_ tracks: [Track]) async {
        for t in tracks { _ = await download(t) }
    }

    func removeDownload(_ track: Track) {
        if let sid = SubsonicID.serverID(for: track) { pinnedIDs.remove(sid); savePinned() }
        try? FileManager.default.removeItem(at: track.url)
    }

    private func savePinned() {
        UserDefaults.standard.set(Array(pinnedIDs), forKey: pinnedKey)
    }

    var cacheSize: Int64 { SubsonicCache.sizeOnDisk() }
    func clearCache() { SubsonicCache.clear() }

    // MARK: - Playback seam + scrobble
    /// Resolve a track to a local file the engine can open — returns instantly for
    /// local files, downloads-then-returns for a remote one. nil if unreachable.
    func ensureLocal(_ track: Track) async -> URL? {
        if !SubsonicID.isRemote(track) {
            return FileManager.default.fileExists(atPath: track.url.path) ? track.url : nil
        }
        guard let client = store.client, let sid = SubsonicID.serverID(for: track) else {
            return SubsonicCache.isCached(track.url) ? track.url : nil
        }
        let suffix = track.url.pathExtension.isEmpty ? "mp3" : track.url.pathExtension
        return try? await SubsonicCache.ensureCached(id: sid, suffix: suffix, using: client)
    }

    func scrobble(_ track: Track) {
        guard let client = store.client, let sid = SubsonicID.serverID(for: track) else { return }
        Task { try? await client.scrobble(id: sid, submission: true) }
    }

    // MARK: - Helpers
    private static func fetchThumbnail(_ url: URL) async -> Data? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return LibraryStore.thumbnail(from: data)
    }
}
