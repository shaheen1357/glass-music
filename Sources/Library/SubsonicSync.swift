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
    enum Availability { case local, downloaded, downloading, waiting, failed, cached, streams }

    let store: SubsonicStore
    private unowned let library: LibraryStore
    private unowned let playlists: PlaylistStore

    private(set) var state: State = .idle
    private(set) var lastSynced: Date?
    private(set) var progressText: String?        // live "Syncing… N songs" for the UI

    /// Every server id that should be on the phone: manualIDs plus the songs of every
    /// downloaded playlist or album. Recomputed by reconcileDownloads().
    private(set) var pinnedIDs: Set<String> = []
    /// Songs downloaded one by one from their ••• menu.
    private(set) var manualIDs: Set<String> = []
    /// Downloaded playlists and albums ("playlist:<id>", "album:<id>").
    private(set) var downloadRules: Set<String> = []
    /// Queued in the background session (running, or waiting for Wi-Fi).
    private(set) var queuedIDs: Set<String> = []
    /// Downloads that failed; shown with a retry, never retried silently.
    private(set) var failedIDs: Set<String> = []
    /// Songs you chose to fetch over mobile data despite the Wi-Fi-only default.
    private var cellularAllowedIDs: Set<String> = []
    private(set) var downloadOnMobileData = UserDefaults.standard.bool(forKey: "downloads.onMobileData")
    /// Server ids being fetched right now (download button or playback).
    private(set) var fetchingIDs: Set<String> = []
    /// How far each of those fetches has got, 0...1, for the download rings.
    private(set) var fetchProgress: [String: Double] = [:]
    /// Bumped whenever a file lands in or leaves the stream cache. The cache is files
    /// on disk, which SwiftUI can't observe; reading this in availability() makes a
    /// row's badge redraw the moment its download finishes.
    private(set) var cacheVersion = 0
    /// One fetch per song: a second request for the same id (playback starting while
    /// the Download button fetches it, or the next-track prefetch) awaits the first
    /// instead of downloading over the file the player may already have open.
    @ObservationIgnored private var inflight: [String: Task<URL?, Never>] = [:]
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
        let d = UserDefaults.standard
        manualIDs = Set(d.stringArray(forKey: pinnedKey) ?? [])
        downloadRules = Set(d.stringArray(forKey: "downloads.rules") ?? [])
        failedIDs = Set(d.stringArray(forKey: "downloads.failed") ?? [])
        cellularAllowedIDs = Set(d.stringArray(forKey: "downloads.cellularAllowed") ?? [])
        pinnedIDs = manualIDs
        restoreDownloads()
    }

    var isConfigured: Bool { store.isConfigured }

    // MARK: - Automatic sync (no button — runs on launch/foreground)
    /// The one-time repair and a fresh-install restore run through the full sync; after
    /// that, opening the app is cheap.
    private var repairDone: Bool {
        get { UserDefaults.standard.bool(forKey: "sync.playlistRepairDone") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.playlistRepairDone") }
    }
    /// Set after the first full catalog walk that records each server song's real path.
    /// Older installs cached the catalog without paths, so they need one full walk to
    /// match by file name; delta syncs only add new albums and would never backfill.
    private var pathCatalogDone: Bool {
        get { UserDefaults.standard.bool(forKey: "sync.pathCatalogDone") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.pathCatalogDone") }
    }
    /// The server's media count at the last sync — the cheap "did anything change?" test.
    private var lastScanCount: Int {
        get { UserDefaults.standard.integer(forKey: "sync.lastScanCount") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastScanCount") }
    }
    /// The missing playlist entries the last catalog diff ran for, so entries the
    /// server itself no longer has don't trigger a diff on every open.
    private var lastDiffedMissing: String {
        get { UserDefaults.standard.string(forKey: "sync.lastDiffedMissing") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastDiffedMissing") }
    }
    private var lastPushedSignature: String {
        get { UserDefaults.standard.string(forKey: "sync.lastPushedSignature") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "sync.lastPushedSignature") }
    }
    /// Each server playlist's last-modified stamp as of our last look. The song-count
    /// probe can't see a song added to a playlist in the web UI; a moved stamp can.
    private var playlistStamps: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "sync.playlistStamps") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "sync.playlistStamps") }
    }
    private static func stamp(_ p: SubPlaylist) -> String { "\(p.changed ?? "")|\(p.songCount ?? -1)" }
    private func recordStamps(_ lists: [SubPlaylist]) {
        playlistStamps = Dictionary(lists.map { ($0.id, Self.stamp($0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// One sync at a time. Foregrounding mid-walk used to start a second full walk on
    /// top of the first (and an interrupted one restarted from scratch every open).
    private var syncInFlight = false

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
        guard !syncInFlight, let client = store.client, !library.effectiveOffline else { return }
        if net.isCellular && !useMobileData { return }
        syncInFlight = true
        defer { syncInFlight = false }
        if shouldRestore() || !repairDone || !pathCatalogDone { await fullSync(); return }

        // Diff the catalog when the song count moved, or when a playlist points at a
        // server song the catalog lacks. The count alone isn't enough: an older build
        // recorded it before fetching, so a song it skipped stayed a greyed placeholder
        // with the count already "seen".
        let count = await serverSongCountChanged(client)
        let missing = playlists.serverEntriesMissing(from: library).sorted().joined(separator: ",")
        if count != nil || (!missing.isEmpty && missing != lastDiffedMissing) {
            // Record only once the diff landed, so a failed pull retries.
            if (try? await syncCatalogDelta(client)) != nil {
                if let count { lastScanCount = count }
                lastDiffedMissing = playlists.serverEntriesMissing(from: library).sorted().joined(separator: ",")
            }
            try? await reconcilePlaylists(client, mode: .merge)
        } else {
            try? await reconcilePlaylists(client, mode: .additive)
        }
        lastSynced = Date()
        reconcileDownloads()                    // downloaded playlists follow their edits
    }

    /// The server's media count if it differs from last sync, else nil. One cheap
    /// request that gates the catalog diff.
    private func serverSongCountChanged(_ client: SubsonicClient) async -> Int? {
        guard let status = try? await client.scanStatus(), !status.scanning else { return nil }
        return status.count != lastScanCount ? status.count : nil
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
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        await fullSync()
    }

    private func fullSync() async {
        guard let client = store.client else { return }
        state = .syncing
        do {
            try await syncCatalog(client)                        // read-only mirror for streaming + dedup
            pathCatalogDone = true    // paths are in; a later playlist/likes error mustn't re-walk
            if let status = try? await client.scanStatus() { lastScanCount = status.count }

            // Server wins for shared playlists on a fresh install or the one-time repair;
            // after that it's a three-way merge so neither side's edits are lost.
            let mode: ReconcileMode = (shouldRestore() || !repairDone) ? .authoritative : .merge
            try await reconcilePlaylists(client, mode: mode)
            try await syncLiked(client)

            repairDone = true
            libraryProvisioned = true
            reconcileDownloads()
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
            if let fresh = try? await client.serverPlaylists() { recordStamps(fresh) }
        case .merge:
            let server = await resolve(lists, client)
            playlists.mergeServerPlaylists(server, using: library)
            recordStamps(lists)
            await pushPlaylists()
        case .additive:
            // Cheap path: only resolve (fetch songs for) playlists the phone lacks, so a
            // new server playlist like hindi arrives without re-pulling everything...
            let haveIDs = Set(playlists.playlists.compactMap { $0.serverID })
            let haveNames = Set(playlists.playlists.filter { $0.kind == .user }.map { $0.name })
            let newOnes = lists.filter { !haveIDs.contains($0.id) && !haveNames.contains($0.name ?? "") }
            if !newOnes.isEmpty { playlists.applyServerPlaylists(await resolve(newOnes, client)) }
            // ...and the ones the phone has whose server stamp moved (a song added in the
            // web UI), merged before any push so the push can't overwrite that edit. With
            // no stamps yet (first run of this build) every known list merges once.
            let stamps = playlistStamps
            let moved = lists.filter { haveIDs.contains($0.id) && stamps[$0.id] != Self.stamp($0) }
            if !moved.isEmpty { playlists.mergeServerPlaylists(await resolve(moved, client), using: library) }
            recordStamps(lists)
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

    /// The server's song count moved: diff the whole song list (a few paged search3
    /// requests, the same as the full sync) against the catalog we hold, fold in the new
    /// songs and drop the deleted ones in one rebuild. The old delta walked newest albums,
    /// but Navidrome dates an album by its OLDEST song, so a track added to an album the
    /// server already had never surfaced — not in search, and only as a placeholder in a
    /// playlist. Cover art is fetched only for the new songs.
    private func syncCatalogDelta(_ client: SubsonicClient) async throws {
        defer { progressText = nil }
        let fresh = try await fetchCatalog(client)
        guard !fresh.tracks.isEmpty else { return }          // never wipe on an empty reply
        let known = Set(library.remoteTracks.map { $0.id })
        let freshIDs = Set(fresh.tracks.map { $0.id })
        let added = fresh.tracks.filter { !known.contains($0.id) }
        let removed = known.subtracting(freshIDs)
        guard !added.isEmpty || !removed.isEmpty else { return }
        library.applyRemoteDelta(added: added, removedIDs: removed)
        let addedIDs = Set(added.map { $0.id })
        let jobs = fresh.idsByCover.compactMap { cover, ids -> (cover: String, ids: [String])? in
            let mine = ids.filter { addedIDs.contains($0) }
            return mine.isEmpty ? nil : (cover, mine)
        }
        Task { @MainActor [weak self] in await self?.backfillArtwork(jobs, client: client) }
    }

    /// Restore (server→library) is allowed only on a never-provisioned install whose
    /// library is genuinely empty. After that the gate is shut for this install.
    private func shouldRestore() -> Bool {
        !libraryProvisioned && library.isLocalEmpty && playlists.userPlaylistsEmpty
    }

    private func syncCatalog(_ client: SubsonicClient) async throws {
        // Every song in a few paged search3 requests (500 a page), then ONE merge into
        // the library. The old walk fetched each album separately and re-merged every
        // third album — a full re-sort, regroup and republish on the main thread each
        // time, ~113 of them for 340 albums, which is what froze the UI. Cover art
        // follows in the background, grouped by cover id (one fetch per album cover).
        let fresh = try await fetchCatalog(client)
        library.mergeRemote(fresh.tracks, persist: true)     // the one merge + cache
        progressText = nil
        let jobs = fresh.idsByCover.map { (cover: $0.key, ids: $0.value) }
        Task { @MainActor [weak self] in await self?.backfillArtwork(jobs, client: client) }
    }

    /// The server's whole song list, paged through search3. The running count is plain
    /// text, so it stays live for free. Throws on an empty list from a server that does
    /// have songs (this search form unsupported), so the cached catalog is never wiped.
    private func fetchCatalog(_ client: SubsonicClient) async throws
        -> (tracks: [Track], idsByCover: [String: [String]]) {
        var all: [Track] = []
        var idsByCover: [String: [String]] = [:]
        var offset = 0
        let pageSize = 500
        while true {
            let page = try await client.allSongs(size: pageSize, offset: offset)
            for c in page {
                let t = client.track(from: c)
                all.append(t)
                if let cover = c.coverArt { idsByCover[cover, default: []].append(t.id) }
            }
            offset += page.count
            progressText = "Syncing library… \(all.count) songs"
            if page.count < pageSize { break }
        }
        if all.isEmpty, let status = try? await client.scanStatus(), status.count > 0 {
            throw SubsonicError.malformed
        }
        return (all, idsByCover)
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
            // Apply in batches so covers pop in as they arrive, not all at the end. Each
            // apply re-merges the library and rewrites the catalog cache, so batches are
            // wide (150 songs) to keep that to a handful of passes.
            if art.count >= 150 || i == jobs.count - 1 {
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
        // Pull: fold server stars into Liked (union; never drops a local like).
        playlists.mergeLikedFromServer(songs.map { SubsonicID.prefix + $0.id })
    }

    /// Star any liked song that has a server copy but isn't starred on the server yet.
    /// Runs on every push path, so a like made while offline reaches the server on the
    /// next ordinary open — the immediate star at like-time can't, with no connection.
    private func pushLikedStars(_ client: SubsonicClient) async {
        guard let songs = try? await client.starredSongs() else { return }
        let starred = Set(songs.map { $0.id })
        for sid in likedServerIDs() where !starred.contains(sid) {
            try? await client.star(id: sid, starred: true)
        }
    }

    /// Server ids for the phone's currently-liked songs — each song's own server id, or a
    /// local file's server twin by content. Local-only songs with no server copy are
    /// skipped (there's nothing to star yet).
    private func likedServerIDs() -> [String] {
        guard let liked = playlists.liked else { return [] }
        return liked.trackIDs.compactMap { id in
            if id.hasPrefix(SubsonicID.prefix) { return String(id.dropFirst(SubsonicID.prefix.count)) }
            if let t = library.tracksByID[id], let twin = library.remoteTwin(of: t) {
                return SubsonicID.serverID(for: twin)
            }
            return nil
        }
    }

    // MARK: - Push local user playlists to the server (phone edits mirror up)
    /// Map a phone playlist's entries to server song ids — its own, or a local file's
    /// server twin. A local-only song with no server copy is dropped from the pushed
    /// copy (the server can't hold audio it doesn't have) but stays on the phone.
    /// `unmatched` counts the songs the server DOES seem to have (same title) yet no
    /// twin was found for — a failed match, not a phone-only song.
    /// `sent` is the phone entries that made it into `ids` — what the server will hold.
    private func mapSongIDs(_ pl: Playlist) -> (ids: [String], unmatched: [String], sent: [String]) {
        var ids: [String] = []
        var unmatched: [String] = []
        var sent: [String] = []
        for id in pl.trackIDs {
            if id.hasPrefix(SubsonicID.prefix) {
                ids.append(String(id.dropFirst(SubsonicID.prefix.count))); sent.append(id); continue
            }
            guard let t = library.tracksByID[id] else { continue }
            if let twin = library.remoteTwin(of: t), let sid = SubsonicID.serverID(for: twin) {
                ids.append(sid); sent.append(id)
            } else if library.serverHasTitle(t.title) {
                unmatched.append(t.title)
            }
        }
        return (ids, unmatched, sent)
    }

    /// Playlists held back from the last push because some songs failed to match —
    /// shown in Settings so a mismatch is visible instead of silently shrinking the
    /// server's copy (setPlaylist replaces the whole list).
    private(set) var pushWarning: String?

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

        // A server list that changed since we last looked (edited in the web UI after
        // the last open) is merged in first — setPlaylist replaces the whole list, so
        // pushing the phone's copy blind would erase that edit.
        let stamps = playlistStamps
        let mine = Set(playlists.playlists.compactMap { $0.serverID })
        let moved = serverLists.filter { mine.contains($0.id) && stamps[$0.id] != nil && stamps[$0.id] != Self.stamp($0) }
        if !moved.isEmpty { playlists.mergeServerPlaylists(await resolve(moved, client), using: library) }

        var held: [String] = []
        for pl in playlists.playlists where pl.kind == .user {
            let (songIDs, unmatched, sent) = mapSongIDs(pl)
            guard !songIDs.isEmpty else { continue }
            let target = pl.serverID.flatMap { liveIDs.contains($0) ? $0 : nil } ?? idByName[pl.name]
            if target != nil && !unmatched.isEmpty {
                held.append("\(pl.name) (\(unmatched.count))")
                continue
            }
            do {
                if let target {
                    try await client.setPlaylist(id: target, songIDs: songIDs)
                    if pl.serverID != target { playlists.setServerID(target, forID: pl.id) }
                } else if let created = try await client.createPlaylist(name: pl.name, songIDs: songIDs) {
                    playlists.setServerID(created.id, forID: pl.id)
                    idByName[pl.name] = created.id   // guard a same-named sibling in this same pass
                }
                playlists.markSynced(id: pl.id, entryIDs: sent, using: library)
            } catch { /* best-effort per playlist */ }
        }
        pushWarning = held.isEmpty ? nil
            : "Not synced — songs didn't match the server: " + held.joined(separator: ", ")
        // Our own pushes moved the server's stamps; record them so the next open
        // doesn't mistake them for web-UI edits.
        if let fresh = try? await client.serverPlaylists() { recordStamps(fresh) }
        await pushLikedStars(client)
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
            let mapped = mapSongIDs(pl)
            guard !mapped.ids.isEmpty else { continue }
            if let created = try? await client.createPlaylist(name: pl.name, songIDs: mapped.ids) {
                playlists.setServerID(created.id, forID: pl.id)
                playlists.markSynced(id: pl.id, entryIDs: mapped.sent, using: library)
            }
        }
        await pushLikedStars(client)
    }

    // MARK: - Offline availability / downloads
    //
    // What should be on the phone = songs downloaded one by one (manualIDs) plus every
    // server song in a downloaded playlist or album (downloadRules), recomputed by
    // reconcileDownloads() after each sync and each change. So a downloaded playlist
    // stays downloaded: songs added later download, songs removed are deleted unless
    // another download still wants them. What IS on the phone is read from disk.

    func availability(_ track: Track) -> Availability {
        if !SubsonicID.isRemote(track) { return .local }
        _ = cacheVersion
        guard let sid = SubsonicID.serverID(for: track) else { return .streams }
        if SubsonicCache.isDownloaded(track.url) { return .downloaded }
        if pinnedIDs.contains(sid) {
            if failedIDs.contains(sid) { return .failed }
            if queuedIDs.contains(sid) { return isWaitingForWiFi(sid) ? .waiting : .downloading }
        }
        return SubsonicCache.isCached(track.url) ? .cached : .streams
    }

    /// Fraction downloaded so far for a song being downloaded for offline, else nil.
    func downloadProgress(_ track: Track) -> Double? {
        guard let sid = SubsonicID.serverID(for: track), queuedIDs.contains(sid) else { return nil }
        return fetchProgress[sid] ?? 0
    }

    var isOnCellular: Bool { net.isCellular }

    private func isWaitingForWiFi(_ sid: String) -> Bool {
        net.isCellular && !downloadOnMobileData && !cellularAllowedIDs.contains(sid)
    }

    // Single songs (a song's ••• menu)
    func isManuallyDownloaded(_ track: Track) -> Bool {
        guard let sid = SubsonicID.serverID(for: track) else { return false }
        return manualIDs.contains(sid)
    }

    /// True when a downloaded playlist or album keeps this song on the phone.
    func isHeldByCollection(_ track: Track) -> Bool {
        guard let sid = SubsonicID.serverID(for: track) else { return false }
        return downloadRules.contains { serverIDs(forRule: $0).contains(sid) }
    }

    func download(_ track: Track, allowCellular: Bool = false) {
        guard SubsonicID.isRemote(track), let sid = SubsonicID.serverID(for: track) else { return }
        manualIDs.insert(sid)
        if allowCellular { cellularAllowedIDs.insert(sid) }
        saveDownloadState()
        reconcileDownloads()
    }

    func removeDownload(_ track: Track) {
        guard let sid = SubsonicID.serverID(for: track) else { return }
        manualIDs.remove(sid)
        saveDownloadState()
        reconcileDownloads()
    }

    // Playlists and albums: "playlist:<id>", "album:<id>"
    static func ruleKey(playlistID: String) -> String { "playlist:\(playlistID)" }
    static func ruleKey(albumID: String) -> String { "album:\(albumID)" }

    func isDownloadRule(_ key: String) -> Bool { downloadRules.contains(key) }

    func setDownloadRule(_ key: String, on: Bool, allowCellular: Bool = false) {
        if on {
            downloadRules.insert(key)
            if allowCellular { cellularAllowedIDs.formUnion(serverIDs(forRule: key)) }
        } else {
            downloadRules.remove(key)
        }
        saveDownloadState()
        reconcileDownloads()
    }

    /// Where a playlist's or album's songs stand, for its download button.
    struct CollectionStatus {
        var total = 0, done = 0, waiting = 0, failed = 0
        var partial = 0.0
        var fraction: Double { total == 0 ? 0 : (Double(done) + partial) / Double(total) }
        var complete: Bool { done == total }
    }

    func status(of tracks: [Track]) -> CollectionStatus {
        var s = CollectionStatus()
        for t in tracks where SubsonicID.isRemote(t) {
            s.total += 1
            switch availability(t) {
            case .downloaded: s.done += 1
            case .waiting: s.waiting += 1
            case .failed: s.failed += 1
            case .downloading: s.partial += downloadProgress(t) ?? 0
            default: break
            }
        }
        return s
    }

    // Downloads screen
    struct DownloadsSnapshot {
        var downloading: [Track] = [], waiting: [Track] = [], failed: [Track] = [], done: [Track] = []
    }

    func downloadsSnapshot() -> DownloadsSnapshot {
        _ = cacheVersion
        var s = DownloadsSnapshot()
        let byID = remoteTracksByID()
        for sid in pinnedIDs.sorted() {
            guard let t = byID[sid] else { continue }
            switch availability(t) {
            case .downloaded: s.done.append(t)
            case .waiting: s.waiting.append(t)
            case .failed: s.failed.append(t)
            case .downloading: s.downloading.append(t)
            default: break
            }
        }
        s.done.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return s
    }

    func retryFailed() {
        failedIDs.removeAll()
        reconcileDownloads()
    }

    /// The one-tap override: queued downloads go now, over mobile data.
    func downloadWaitingOnMobileData() {
        let waiting = queuedIDs.filter(isWaitingForWiFi)
        guard !waiting.isEmpty else { return }
        cellularAllowedIDs.formUnion(waiting)
        BackgroundDownloads.shared.cancel(ids: waiting)       // re-queued below, allowed
        queuedIDs.subtract(waiting)
        saveDownloadState()
        reconcileDownloads(requeue: waiting)
    }

    func removeAllDownloads() {
        manualIDs.removeAll()
        downloadRules.removeAll()
        cellularAllowedIDs.removeAll()
        failedIDs.removeAll()
        BackgroundDownloads.shared.cancelAll()
        queuedIDs.removeAll()
        // Delete outright rather than leave it to reconcile, which holds deletion back
        // until the catalog has loaded: "Remove All" means now, whatever state we're in.
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: SubsonicCache.downloadsDir, includingPropertiesForKeys: nil) {
            for f in files { SubsonicCache.removeDownload(SubsonicCache.dir.appendingPathComponent(f.lastPathComponent)) }
        }
        saveDownloadState()
        reconcileDownloads()
    }

    func setDownloadOnMobileData(_ on: Bool) {
        downloadOnMobileData = on
        UserDefaults.standard.set(on, forKey: "downloads.onMobileData")
        if on { downloadWaitingOnMobileData() }
    }

    /// Bring the phone in line with what should be downloaded: queue what's missing,
    /// delete what nothing wants any more. Deletion only runs once the catalog is
    /// loaded, so a half-started app can never wipe your downloads.
    func reconcileDownloads(requeue: Set<String> = []) {
        downloadRules = downloadRules.filter(ruleTargetExists)
        var desired = manualIDs
        for rule in downloadRules { desired.formUnion(serverIDs(forRule: rule)) }
        pinnedIDs = desired
        failedIDs.formIntersection(desired)
        cellularAllowedIDs.formIntersection(desired)

        let fm = FileManager.default
        let desiredStems = Set(desired.map(SubsonicCache.stem))
        if !library.remoteTracks.isEmpty,
           let files = try? fm.contentsOfDirectory(at: SubsonicCache.downloadsDir, includingPropertiesForKeys: nil) {
            for f in files where !desiredStems.contains(f.deletingPathExtension().lastPathComponent) {
                SubsonicCache.removeDownload(SubsonicCache.dir.appendingPathComponent(f.lastPathComponent))
            }
        }
        let gone = queuedIDs.subtracting(desired)
        if !gone.isEmpty { BackgroundDownloads.shared.cancel(ids: gone); queuedIDs.subtract(gone) }

        if let client = store.client {
            let byID = remoteTracksByID()
            for sid in desired where !queuedIDs.contains(sid) && !failedIDs.contains(sid) {
                guard let t = byID[sid], !SubsonicCache.isDownloaded(t.url),
                      let url = client.downloadURL(id: sid) else { continue }
                BackgroundDownloads.shared.enqueue(
                    id: sid, fileName: t.url.lastPathComponent, url: url,
                    allowCellular: downloadOnMobileData || cellularAllowedIDs.contains(sid) || requeue.contains(sid))
                queuedIDs.insert(sid)
            }
        }
        saveDownloadState()
        cacheVersion &+= 1
    }

    private func ruleTargetExists(_ rule: String) -> Bool {
        if rule.hasPrefix("playlist:") {
            let id = String(rule.dropFirst("playlist:".count))
            return playlists.playlists.contains { $0.id == id }
        }
        if rule.hasPrefix("album:") {
            // Albums are rebuilt from the catalog; keep the rule until it has loaded.
            let id = String(rule.dropFirst("album:".count))
            return library.albums.isEmpty || library.albums.contains { $0.id == id }
        }
        return false
    }

    private func serverIDs(forRule rule: String) -> Set<String> {
        var tracks: [Track] = []
        if rule.hasPrefix("playlist:") {
            let id = String(rule.dropFirst("playlist:".count))
            if let p = playlists.playlists.first(where: { $0.id == id }) {
                tracks = playlists.tracks(for: p, in: library)
            }
        } else if rule.hasPrefix("album:") {
            let id = String(rule.dropFirst("album:".count))
            tracks = library.albums.first { $0.id == id }?.tracks ?? []
        }
        // A song the phone holds as its own file resolves to that file: nothing to fetch.
        return Set(tracks.compactMap { SubsonicID.isRemote($0) ? SubsonicID.serverID(for: $0) : nil })
    }

    private func remoteTracksByID() -> [String: Track] {
        Dictionary(library.remoteTracks.compactMap { t in SubsonicID.serverID(for: t).map { ($0, t) } },
                   uniquingKeysWith: { a, _ in a })
    }

    private func downloadFinished(_ sid: String, landed: Bool, cancelled: Bool, bytes: Int64) {
        // A cancel is always ours (removed, or re-queued to go over mobile data), and
        // the bookkeeping was done when we cancelled. Acting on it here could clear a
        // song re-queued a moment ago.
        guard !cancelled else { return }
        queuedIDs.remove(sid)
        fetchProgress[sid] = nil
        if landed {
            failedIDs.remove(sid)
            addDataUsed(Int(bytes))
        } else if !cancelled && pinnedIDs.contains(sid) {
            failedIDs.insert(sid)
        }
        saveDownloadState()
        cacheVersion &+= 1
    }

    /// Startup: hook up the background session, carry earlier builds' downloads over,
    /// and restore links iOS may have cleared along with the stream cache.
    private func restoreDownloads() {
        let bg = BackgroundDownloads.shared
        bg.onProgress = { [weak self] sid, f in
            guard let self, self.queuedIDs.contains(sid) else { return }
            self.fetchProgress[sid] = f
        }
        bg.onFinished = { [weak self] sid, landed, cancelled, bytes in
            self?.downloadFinished(sid, landed: landed, cancelled: cancelled, bytes: bytes)
        }
        bg.start()

        let fm = FileManager.default
        // Earlier builds kept downloads as plain files in the stream cache.
        let legacy = Set(manualIDs.map(SubsonicCache.stem))
        if let items = try? fm.contentsOfDirectory(at: SubsonicCache.dir, includingPropertiesForKeys: nil) {
            for u in items where !SubsonicCache.isLink(u) && legacy.contains(u.deletingPathExtension().lastPathComponent) {
                let dest = SubsonicCache.downloadedFile(for: u)
                if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: u, to: dest) }
                SubsonicCache.link(u)
            }
        }
        if let files = try? fm.contentsOfDirectory(at: SubsonicCache.downloadsDir, includingPropertiesForKeys: nil) {
            for f in files { SubsonicCache.link(SubsonicCache.dir.appendingPathComponent(f.lastPathComponent)) }
        }
        Task { @MainActor [weak self] in
            let active = await bg.activeIDs()
            self?.queuedIDs.formUnion(active)
            self?.cacheVersion &+= 1
        }
    }

    private func saveDownloadState() {
        let d = UserDefaults.standard
        d.set(Array(manualIDs), forKey: pinnedKey)
        d.set(Array(downloadRules), forKey: "downloads.rules")
        d.set(Array(failedIDs), forKey: "downloads.failed")
        d.set(Array(cellularAllowedIDs), forKey: "downloads.cellularAllowed")
    }

    /// What's on the phone from the server, split the way it's managed: downloads you
    /// chose (kept until removed) and the play cache (kept under 2 GB on its own).
    var storageSizes: (downloads: Int64, cache: Int64) {
        _ = cacheVersion
        return SubsonicCache.sizes()
    }

    /// Clears the play cache only. Downloads stay.
    func clearCache() { SubsonicCache.clear(); cacheVersion &+= 1 }

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
        if SubsonicCache.isDownloaded(track.url) { SubsonicCache.link(track.url); return track.url }
        if SubsonicCache.isCached(track.url) { return track.url }
        if let running = inflight[sid] { return await running.value }
        let suffix = track.url.pathExtension.isEmpty ? "mp3" : track.url.pathExtension
        fetchingIDs.insert(sid)
        fetchProgress[sid] = 0
        let task = Task<URL?, Never> {
            try? await SubsonicCache.ensureCached(id: sid, suffix: suffix, using: client) { [weak self] f in
                Task { @MainActor in
                    guard let self, self.fetchingIDs.contains(sid) else { return }
                    self.fetchProgress[sid] = f
                }
            }
        }
        inflight[sid] = task
        let url = await task.value
        inflight[sid] = nil
        fetchingIDs.remove(sid)
        fetchProgress[sid] = nil
        if let url {
            addDataUsed((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            trimCache()
        }
        cacheVersion &+= 1
        return url
    }

    /// Keep the play cache under its 2 GB ceiling by evicting its oldest files.
    /// Downloads neither count toward the ceiling nor get evicted: they used to be
    /// counted, so once downloads passed 2 GB every cached song was thrown out.
    private func trimCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: SubsonicCache.dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let cached = items.filter { !SubsonicCache.isLink($0) }    // links point at downloads
        var total = cached.reduce(0) { $0 + Int(((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
        guard total > cacheCapBytes else { return }
        let evictable = cached
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
        cacheVersion &+= 1
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
