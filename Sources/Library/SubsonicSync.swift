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

    // Cellular / data controls.
    private let net = NetworkMonitor()
    var useMobileData = UserDefaults.standard.bool(forKey: "subsonic.useMobileData")
    private(set) var dataUsedBytes = UserDefaults.standard.integer(forKey: "subsonic.dataUsed")
    private let cacheCapBytes = 2 * 1024 * 1024 * 1024   // 2 GB auto-cache ceiling (pinned exempt)

    /// The phone is the source of truth. The server only writes back into the library
    /// on a fresh install (restore), decided by THIS flag — never by a song count, so a
    /// deliberately-emptied library is never restored over. Once set, the gate is shut
    /// for this install and sync is strictly phone→server for library/playlist content.
    var libraryProvisioned: Bool {
        get { UserDefaults.standard.bool(forKey: "library.provisioned") }
        set { UserDefaults.standard.set(newValue, forKey: "library.provisioned") }
    }

    init(store: SubsonicStore, library: LibraryStore, playlists: PlaylistStore) {
        self.store = store
        self.library = library
        self.playlists = playlists
        pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
    }

    var isConfigured: Bool { store.isConfigured }

    // MARK: - Automatic sync (no button — runs on launch/foreground)
    /// The one-time repair and a fresh-install restore run through the full sync; after
    /// that, opening the app is cheap.
    private var repairDone: Bool {
        get { UserDefaults.standard.bool(forKey: "sync.playlistRepairDone") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.playlistRepairDone") }
    }
    /// The server's media count at the last sync — the cheap "did anything change?" test.
    private var lastScanCount: Int {
        get { UserDefaults.standard.integer(forKey: "sync.lastScanCount") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastScanCount") }
    }
    private var lastPushedSignature: String {
        get { UserDefaults.standard.string(forKey: "sync.lastPushedSignature") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastPushedSignature") }
    }
    /// Album ids already folded into the catalog, so a delta pull fetches only new ones.
    private var syncedAlbumIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "sync.albumIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "sync.albumIDs") }
    }

    private enum ReconcileMode { case authoritative, merge, additive }

    /// A fingerprint of the user's playlists, so an automatic sync pushes only when
    /// something actually changed on the phone — not on every launch or foreground.
    private func playlistSignature() -> String {
        playlists.playlists
            .filter { $0.kind == .user || $0.kind == .liked }
            .map { "\($0.id)=\($0.name)=\($0.trackIDs.joined(separator: ","))" }
            .joined(separator: "|")
    }

    /// Runs on launch and foreground. The full catalog walk never happens here except
    /// once — a fresh install or the one-time repair. Normally it's a tiny probe: pull
    /// the delta only if the server's song count moved, bring down any new playlist, and
    /// push the phone's edits only when they changed. This is what keeps opening the app
    /// from re-syncing the whole library every time.
    func autoSyncIfAllowed() async {
        guard let client = store.client, !library.effectiveOffline else { return }
        if net.isCellular && !useMobileData { return }
        if shouldRestore() || !repairDone { await syncNow(); return }

        if await serverSongCountChanged(client) {
            try? await syncCatalogDelta(client)
            try? await reconcilePlaylists(client, mode: .merge)
        } else {
            try? await reconcilePlaylists(client, mode: .additive)
        }
        lastSynced = Date()
    }

    /// True if the server's media count differs from last sync (and records the new
    /// count). One cheap request that gates the whole catalog walk.
    private func serverSongCountChanged(_ client: SubsonicClient) async -> Bool {
        guard let status = try? await client.scanStatus(), !status.scanning else { return false }
        guard status.count != lastScanCount else { return false }
        lastScanCount = status.count
        return true
    }

    /// Push the phone's playlists up when they differ from what we last sent. Fire-and-
    /// forget, called on backgrounding so an edit is mirrored promptly.
    func pushIfChanged() {
        guard store.isConfigured, !library.effectiveOffline, repairDone else { return }
        if net.isCellular && !useMobileData { return }
        guard playlistSignature() != lastPushedSignature else { return }
        Task { await pushPlaylists(); lastPushedSignature = playlistSignature() }
    }

    func setUseMobileData(_ on: Bool) {
        useMobileData = on
        UserDefaults.standard.set(on, forKey: "subsonic.useMobileData")
    }

    var dataUsedText: String {
        ByteCountFormatter.string(fromByteCount: Int64(dataUsedBytes), countStyle: .file)
    }
    func resetDataUsed() {
        dataUsedBytes = 0
        UserDefaults.standard.set(0, forKey: "subsonic.dataUsed")
    }
    private func addDataUsed(_ bytes: Int) {
        dataUsedBytes += bytes
        UserDefaults.standard.set(dataUsedBytes, forKey: "subsonic.dataUsed")
    }

    // MARK: - Full sync (streaming-client model: the server is the source of truth)
    /// The heavy path: walk the whole catalog, then reconcile playlists. Used by pull-to-
    /// refresh, the fresh-install restore, and the one-time repair — never on a plain app
    /// open (that goes through autoSyncIfAllowed's cheap probe).
    func syncNow() async {
        guard let client = store.client else { return }
        state = .syncing
        do {
            try await syncCatalog(client)                        // read-only mirror for streaming + dedup
            if let status = try? await client.scanStatus() { lastScanCount = status.count }

            // Server wins for shared playlists on a fresh install or the one-time repair;
            // after that it's a three-way merge so neither side's edits are lost.
            let mode: ReconcileMode = (shouldRestore() || !repairDone) ? .authoritative : .merge
            try await reconcilePlaylists(client, mode: mode)
            try await syncLiked(client)

            repairDone = true
            libraryProvisioned = true
            lastPushedSignature = playlistSignature()
            lastSynced = Date()
            state = .done
            progressText = nil
        } catch {
            progressText = nil
            state = .failed((error as? SubsonicError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Bring playlists into agreement with the server, per mode. Content keys are
    /// backfilled first so merges compare by song identity, not by local filename.
    private func reconcilePlaylists(_ client: SubsonicClient, mode: ReconcileMode) async throws {
        playlists.reconcileKeys(using: library)
        let lists = try await client.serverPlaylists()
        switch mode {
        case .authoritative:
            progressText = "Restoring playlists…"
            let server = await resolve(lists, client)
            playlists.applyServerPlaylistsAuthoritative(server)
            await pushPhoneOnlyPlaylists(client, server: server)
        case .merge:
            let server = await resolve(lists, client)
            playlists.mergeServerPlaylists(server, using: library)
            await pushPlaylists()
        case .additive:
            // Cheap path: only resolve (fetch songs for) playlists the phone lacks, so a
            // new server playlist like hindi arrives without re-pulling everything.
            let haveIDs = Set(playlists.playlists.compactMap { $0.serverID })
            let haveNames = Set(playlists.playlists.filter { $0.kind == .user }.map { $0.name })
            let newOnes = lists.filter { !haveIDs.contains($0.id) && !haveNames.contains($0.name ?? "") }
            if !newOnes.isEmpty { playlists.applyServerPlaylists(await resolve(newOnes, client)) }
            if playlistSignature() != lastPushedSignature { await pushPlaylists() }
        }
        lastPushedSignature = playlistSignature()
        progressText = nil
    }

    /// Resolve server playlists to full entries (one getPlaylist each) with a content key
    /// and a metadata snapshot per song.
    private func resolve(_ lists: [SubPlaylist], _ client: SubsonicClient) async -> [PlaylistStore.ServerPlaylist] {
        var out: [PlaylistStore.ServerPlaylist] = []
        for pl in lists {
            guard let (_, songs) = try? await client.playlist(id: pl.id) else { continue }
            let entries = songs.map { c -> PlaylistStore.ServerEntry in
                let t = client.track(from: c)
                return PlaylistStore.ServerEntry(
                    id: SubsonicID.prefix + c.id, key: t.contentKey,
                    meta: TrackMeta(title: t.title, artist: t.artist, album: t.album, duration: t.duration))
            }
            out.append(PlaylistStore.ServerPlaylist(serverID: pl.id, name: pl.name ?? "Playlist", entries: entries))
        }
        return out
    }

    /// Pull only the albums added since the last sync (newest-first until we hit ones we
    /// already have) and fold them in — so a grown server doesn't trigger a full walk.
    private func syncCatalogDelta(_ client: SubsonicClient) async throws {
        let known = syncedAlbumIDs
        var newTracks: [Track] = []
        var coverJobs: [(cover: String, ids: [String])] = []
        var newIDs = Set<String>()
        var offset = 0
        let pageSize = 100
        while true {
            let page = try await client.newestAlbums(size: pageSize, offset: offset)
            if page.isEmpty { break }
            var hitKnown = false
            for album in page {
                if known.contains(album.id) { hitKnown = true; continue }
                let songs = (try? await client.songs(forAlbum: album.id)) ?? []
                let mapped = songs.map { client.track(from: $0) }
                newTracks.append(contentsOf: mapped)
                if let cover = album.coverArt { coverJobs.append((cover, mapped.map(\.id))) }
                newIDs.insert(album.id)
            }
            offset += page.count
            if hitKnown || page.count < pageSize { break }
        }
        guard !newTracks.isEmpty else { return }
        library.appendRemote(newTracks)
        syncedAlbumIDs = known.union(newIDs)
        let jobs = coverJobs
        Task { @MainActor [weak self] in await self?.backfillArtwork(jobs, client: client) }
    }

    /// Restore (server→library) is allowed only on a never-provisioned install whose
    /// library is genuinely empty. After that the gate is shut for this install.
    private func shouldRestore() -> Bool {
        !libraryProvisioned && library.isLocalEmpty && playlists.userPlaylistsEmpty
    }

    private func syncCatalog(_ client: SubsonicClient) async throws {
        // Pull albums in bulk (paged), then songs per album, merging incrementally
        // so the library fills in live with a running count — no silent wait. Cover
        // art is fetched afterwards in the background so it never blocks anything.
        var all: [Track] = []
        var coverJobs: [(cover: String, ids: [String])] = []
        var albumIDs = Set<String>()
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
                albumIDs.insert(album.id)
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
        syncedAlbumIDs = albumIDs                            // baseline for later delta pulls
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

    private func syncLiked(_ client: SubsonicClient) async throws {
        let songs = try await client.starredSongs()
        playlists.mergeLikedFromServer(songs.map { SubsonicID.prefix + $0.id })
    }

    // MARK: - Push local user playlists to the server (phone edits mirror up)
    /// Map a phone playlist's entries to server song ids — its own, or a local file's
    /// server twin by content. A local-only song with no server copy is dropped from the
    /// pushed copy (the server can't hold audio it doesn't have) but stays on the phone.
    private func mapSongIDs(_ pl: Playlist) -> [String] {
        pl.trackIDs.compactMap { id in
            if id.hasPrefix(SubsonicID.prefix) { return String(id.dropFirst(SubsonicID.prefix.count)) }
            if let t = library.tracksByID[id], let twin = library.remoteTwin(of: t) {
                return SubsonicID.serverID(for: twin)
            }
            return nil
        }
    }

    /// Guards against two pushes running at once (background + foreground can each
    /// trigger one). Without it, both see a playlist with no server id yet and both
    /// create it — which is where the duplicate pairs on the server came from.
    private var pushInFlight = false

    /// Mirror the phone's user playlists up, idempotently. Each phone playlist maps to
    /// exactly one server playlist — by stored server id, else by name (adopting an
    /// existing one), else created fresh. Reconciling against the server's live list
    /// first means a lost or deleted server id is re-created, never duplicated, and a
    /// stale id never silently drops the playlist. Single-flighted.
    func pushPlaylists() async {
        guard let client = store.client, libraryProvisioned, !pushInFlight else { return }
        pushInFlight = true
        defer { pushInFlight = false }

        let serverLists = (try? await client.serverPlaylists()) ?? []
        let liveIDs = Set(serverLists.map(\.id))
        var idByName: [String: String] = [:]
        for s in serverLists { if let n = s.name { idByName[n] = s.id } }

        for pl in playlists.playlists where pl.kind == .user {
            let songIDs = mapSongIDs(pl)
            guard !songIDs.isEmpty else { continue }
            let target = pl.serverID.flatMap { liveIDs.contains($0) ? $0 : nil } ?? idByName[pl.name]
            do {
                if let target {
                    try await client.setPlaylist(id: target, songIDs: songIDs)
                    if pl.serverID != target { playlists.setServerID(target, forID: pl.id) }
                } else if let created = try await client.createPlaylist(name: pl.name, songIDs: songIDs) {
                    playlists.setServerID(created.id, forID: pl.id)
                    idByName[pl.name] = created.id   // guard a same-named sibling in this same pass
                }
            } catch { /* best-effort per playlist */ }
        }
    }

    /// On a server-authoritative pass, push up only the playlists the server doesn't
    /// already have (by id or name) — a custom phone mix that was never on the server, or
    /// was cleared from it — without disturbing the ones the server owns.
    private func pushPhoneOnlyPlaylists(_ client: SubsonicClient, server: [PlaylistStore.ServerPlaylist]) async {
        let ids = Set(server.map(\.serverID))
        let names = Set(server.map(\.name))
        for pl in playlists.playlists where pl.kind == .user {
            if let sid = pl.serverID, ids.contains(sid) { continue }
            if names.contains(pl.name) { continue }
            let songIDs = mapSongIDs(pl)
            guard !songIDs.isEmpty else { continue }
            if let created = try? await client.createPlaylist(name: pl.name, songIDs: songIDs) {
                playlists.setServerID(created.id, forID: pl.id)
            }
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
        let wasCached = SubsonicCache.isCached(track.url)
        let suffix = track.url.pathExtension.isEmpty ? "mp3" : track.url.pathExtension
        guard let url = try? await SubsonicCache.ensureCached(id: sid, suffix: suffix, using: client) else { return nil }
        if !wasCached {
            addDataUsed((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            trimCache()
        }
        return url
    }

    /// Keep the auto-cache under its ceiling by evicting the oldest non-pinned files.
    /// Downloaded (pinned) tracks are never touched.
    private func trimCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: SubsonicCache.dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = items.reduce(0) { $0 + Int(((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
        guard total > cacheCapBytes else { return }
        let pinned = Set(pinnedIDs.map { $0.replacingOccurrences(of: "/", with: "_") })
        let evictable = items
            .filter { !pinned.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a < b
            }
        for f in evictable where total > cacheCapBytes {
            let size = Int(((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
            try? fm.removeItem(at: f)
            total -= size
        }
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
