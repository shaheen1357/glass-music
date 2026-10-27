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
    private(set) var progressText: String?        // live "Syncing… N songs" for the UI

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
            progressText = "Syncing playlists…"
            try await syncPlaylists(client)
            try await syncLiked(client)
            playlists.reconcileKeys(using: library)
            lastSynced = Date()
            state = .done
            progressText = nil
        } catch {
            progressText = nil
            state = .failed((error as? SubsonicError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func syncCatalog(_ client: SubsonicClient) async throws {
        // Pull albums in bulk (paged), then songs per album, merging incrementally
        // so the library fills in live with a running count — no silent wait. Cover
        // art is fetched afterwards in the background so it never blocks anything.
        var all: [Track] = []
        var coverJobs: [(cover: String, ids: [String])] = []
        var offset = 0
        var processed = 0
        let pageSize = 500
        while true {
            let page = try await client.newestAlbums(size: pageSize, offset: offset)
            if page.isEmpty { break }
            for album in page {
                let songs = (try? await client.songs(forAlbum: album.id)) ?? []
                let mapped = songs.map { client.track(from: $0) }
                all.append(contentsOf: mapped)
                if let cover = album.coverArt { coverJobs.append((cover, mapped.map(\.id))) }
                processed += 1
                // Update the count and paint the library every few albums, so songs
                // appear as they arrive instead of after the whole walk.
                if processed % 3 == 0 {
                    progressText = "Syncing library… \(all.count) songs"
                    library.mergeRemote(all, persist: false)
                }
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        library.mergeRemote(all, persist: true)             // final merge + cache
        progressText = nil
        let jobs = coverJobs
        Task { @MainActor [weak self] in await self?.backfillArtwork(jobs, client: client) }
    }

    /// Fetch one thumbnail per album after the catalog is already usable, and apply
    /// them so artwork appears gradually instead of gating the whole sync.
    private func backfillArtwork(_ jobs: [(cover: String, ids: [String])], client: SubsonicClient) async {
        var art: [String: Data] = [:]
        for (i, job) in jobs.enumerated() {
            if let url = client.coverArtURL(id: job.cover, size: 400),
               let data = await Self.fetchThumbnail(url) {
                for id in job.ids { art[id] = data }
            }
            // Apply in batches so covers pop in as they arrive, not all at the end.
            if art.count >= 40 || i == jobs.count - 1 {
                library.applyRemoteArtwork(art)
                art.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Star / unstar a track on the server (push a Like up). Local-only tracks with
    /// no server copy are skipped.
    func setLiked(_ track: Track, liked: Bool) {
        guard let client = store.client, let sid = SubsonicID.serverID(for: track) else { return }
        Task { try? await client.star(id: sid, starred: liked) }
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
