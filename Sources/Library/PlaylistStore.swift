import Foundation
import Combine

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        // Only the app's default store gets simulator demo content. Tests pass an
        // explicit fileURL, so they start clean (no seeded Liked Songs skewing
        // exact-content assertions).
        let isDefault = fileURL == nil
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true))
                ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("playlists.json")
        }
        load()
        ensureSystemPlaylists()
        if isDefault { seedDemoIfNeeded() }
    }

    private func seedDemoIfNeeded() {
        #if targetEnvironment(simulator)
        guard !playlists.contains(where: { $0.id == "demo-mix" }) else { return }
        playlists.append(Playlist(id: "demo-mix", name: "Chill Mix", kind: .user,
                                  trackIDs: ["demo-0", "demo-2", "demo-4", "demo-1"]))
        if let i = playlists.firstIndex(where: { $0.kind == .liked }) {
            playlists[i].trackIDs = ["demo-3", "demo-5"]
        }
        save()
        #endif
    }

    // MARK: - Persistence
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        // Migrate legacy absolute-path track IDs to stable filenames so playlists
        // survive app reinstalls (the container path changes, filenames don't).
        playlists = decoded.map { pl in
            var p = pl
            p.trackIDs = p.trackIDs.map { ($0 as NSString).lastPathComponent }
            // Re-key every entry from its stored metadata so keys always match the current
            // content-key formula. This repairs entries saved under the old formula (which
            // included track/disc numbers) so a locally-held song resolves to its local
            // file again instead of streaming.
            if let meta = p.trackMeta {
                var keys = p.trackKeys ?? [:]
                for (id, m) in meta { keys[id] = m.contentKey }
                p.trackKeys = keys
            }
            return p
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func ensureSystemPlaylists() {
        if !playlists.contains(where: { $0.kind == .liked }) {
            playlists.insert(Playlist(id: "system.liked", name: "Liked Songs", kind: .liked, trackIDs: []), at: 0)
        }
        if !playlists.contains(where: { $0.kind == .podcasts }) {
            let podcasts = Playlist(id: "system.podcasts", name: "Podcasts", kind: .podcasts, trackIDs: [])
            if let likedIndex = playlists.firstIndex(where: { $0.kind == .liked }) {
                playlists.insert(podcasts, at: likedIndex + 1)
            } else {
                playlists.insert(podcasts, at: 0)
            }
        }
        save()
    }

    // MARK: - Backup
    /// Replace all playlists from a restored backup, guaranteeing the system
    /// playlists (Liked / Podcasts) still exist afterwards.
    func replaceAll(with new: [Playlist]) {
        playlists = new
        ensureSystemPlaylists()   // also saves
    }

    // MARK: - Ordering / pinning
    var orderedPlaylists: [Playlist] {
        playlists.filter { $0.isPinned } + playlists.filter { !$0.isPinned }
    }

    /// No user playlist holds any tracks — part of the "is this a fresh install?"
    /// check that gates a server→library restore.
    var userPlaylistsEmpty: Bool {
        !playlists.contains { $0.kind == .user && !$0.trackIDs.isEmpty }
    }

    func togglePin(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        if playlists[index].isPinned {
            playlists[index].isPinned = false
        } else {
            guard playlists.filter({ $0.isPinned }).count < 20 else { return }
            playlists[index].isPinned = true
        }
        save()
    }

    // MARK: - Liked
    var liked: Playlist? { playlists.first { $0.kind == .liked } }

    func isLiked(_ track: Track) -> Bool {
        liked?.trackIDs.contains(track.id) ?? false
    }

    func toggleLike(_ track: Track) {
        guard let index = playlists.firstIndex(where: { $0.kind == .liked }) else { return }
        if let existing = playlists[index].trackIDs.firstIndex(of: track.id) {
            playlists[index].trackIDs.remove(at: existing)
        } else {
            playlists[index].trackIDs.insert(track.id, at: 0)
            rememberKey(track, at: index)
        }
        save()
    }

    /// Record a track's content identity the moment it's added to a playlist, so the
    /// entry survives the local file being deleted — it then resolves to the server
    /// copy of the same song by content key.
    private func rememberKey(_ track: Track, at index: Int) {
        var keys = playlists[index].trackKeys ?? [:]
        keys[track.id] = track.contentKey
        playlists[index].trackKeys = keys
        var meta = playlists[index].trackMeta ?? [:]
        meta[track.id] = TrackMeta(title: track.title, artist: track.artist,
                                   album: track.album, duration: track.duration)
        playlists[index].trackMeta = meta
    }

    // MARK: - CRUD
    @discardableResult
    func createPlaylist(name: String) -> Playlist {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(id: UUID().uuidString,
                                name: clean.isEmpty ? "New Playlist" : clean,
                                kind: .user, trackIDs: [])
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        save()
    }

    func updateDetails(id: String, name: String, details: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { playlists[index].name = clean }
        playlists[index].details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func setCover(_ data: Data?, forID id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].coverImageData = data
        save()
    }

    // MARK: - M3U import / export
    @discardableResult
    func exportM3U(_ playlist: Playlist, tracks: [Track]) -> URL? {
        var lines = ["#EXTM3U"]
        for t in tracks {
            lines.append("#EXTINF:\(Int(t.duration.rounded())),\(t.artist) - \(t.title)")
            lines.append(t.url.lastPathComponent)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = playlist.name.replacingOccurrences(of: "/", with: "-")
        let url = docs.appendingPathComponent("\(safe).m3u8")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    func importM3U(from url: URL, library: LibraryStore) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let names = content.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { ($0 as NSString).lastPathComponent }
        let byName = Dictionary(library.tracks.map { ($0.url.lastPathComponent, $0.id) },
                                uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        let ids = names.compactMap { byName[$0] }.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        let base = url.deletingPathExtension().lastPathComponent
        playlists.append(Playlist(id: UUID().uuidString,
                                  name: base.isEmpty ? "Imported Playlist" : base,
                                  kind: .user, trackIDs: ids))
        save()
    }

    func delete(_ playlist: Playlist) {
        guard playlist.kind == .user else { return }
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func add(_ track: Track, to playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[index].trackIDs.contains(track.id) {
            playlists[index].trackIDs.append(track.id)
            rememberKey(track, at: index)
            save()
        }
    }

    func addTrackIDs(_ ids: [String], to playlistID: String, allowDuplicates: Bool = false) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in ids where allowDuplicates || !playlists[index].trackIDs.contains(id) {
            playlists[index].trackIDs.append(id)
        }
        save()
    }

    func removeTracks(at offsets: IndexSet, from playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.remove(atOffsets: offsets)
        save()
    }

    func removeTrack(id trackID: String, from playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }
        save()
    }

    func moveTracks(from source: IndexSet, to destination: Int, in playlistID: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Server sync (Subsonic)
    /// Remember each resolvable entry's content key, so it survives the local file
    /// later being deleted — the key then finds the same song from the server.
    func reconcileKeys(using library: LibraryStore) {
        var dirty = false
        for i in playlists.indices {
            var keys = playlists[i].trackKeys ?? [:]
            var meta = playlists[i].trackMeta ?? [:]
            var localChange = false
            for id in playlists[i].trackIDs where keys[id] == nil || meta[id] == nil {
                if let t = library.tracksByID[id] {
                    keys[id] = t.contentKey
                    meta[id] = TrackMeta(title: t.title, artist: t.artist, album: t.album, duration: t.duration)
                    localChange = true
                }
            }
            if localChange { playlists[i].trackKeys = keys; playlists[i].trackMeta = meta; dirty = true }
        }
        if dirty { save() }
    }

    /// One server playlist resolved to durable entries plus a display snapshot.
    struct ServerEntry {
        let id: String        // "subsonic:<songid>"
        let key: String       // content key
        let meta: TrackMeta
    }
    struct ServerPlaylist {
        let serverID: String
        let name: String
        let entries: [ServerEntry]
    }

    /// Additive: bring down only server playlists the phone doesn't already have (by
    /// server id or name). Never overwrites or shrinks an existing one — the cheap open
    /// path, so a new server playlist (e.g. hindi) reaches the phone without disturbing
    /// anything.
    func applyServerPlaylists(_ server: [ServerPlaylist]) {
        var changed = false
        for s in server {
            if playlists.contains(where: { $0.serverID == s.serverID }) { continue }
            if playlists.contains(where: { $0.kind == .user && $0.name == s.name }) { continue }
            appendServerPlaylist(s)
            changed = true
        }
        if changed { save() }
    }

    /// Server-authoritative: the one-time repair and a fresh install. A playlist that
    /// exists on both sides is replaced by the server's copy (matched by server id, then
    /// name); server-only playlists are added. The baseline is seeded from the server so
    /// later syncs merge from a trustworthy start. Phone-only playlists are left for the
    /// caller to push up.
    func applyServerPlaylistsAuthoritative(_ server: [ServerPlaylist]) {
        for s in server {
            if let i = indexMatching(s) {
                setEntries(s.entries, at: i)
                playlists[i].serverID = s.serverID
                playlists[i].syncBaseline = s.entries.map { $0.key }
            } else {
                appendServerPlaylist(s)
            }
        }
        save()
    }

    /// Steady-state three-way merge: for each server playlist matched to a phone one,
    /// combine both sides' changes against the stored baseline — an add on either side
    /// survives, a real removal on either side is honoured. Server-only playlists are
    /// added; phone-only playlists are untouched (the caller pushes them up).
    func mergeServerPlaylists(_ server: [ServerPlaylist], using library: LibraryStore) {
        for s in server {
            guard let i = indexMatching(s) else { appendServerPlaylist(s); continue }
            mergeOne(at: i, server: s, using: library)
            playlists[i].serverID = s.serverID
        }
        save()
    }

    private func indexMatching(_ s: ServerPlaylist) -> Int? {
        playlists.firstIndex(where: { $0.serverID == s.serverID })
            ?? playlists.firstIndex(where: { $0.kind == .user && $0.name == s.name })
    }

    private func appendServerPlaylist(_ s: ServerPlaylist) {
        var p = Playlist(id: UUID().uuidString, name: s.name, kind: .user, trackIDs: [])
        p.serverID = s.serverID
        p.syncBaseline = s.entries.map { $0.key }
        playlists.append(p)
        setEntries(s.entries, at: playlists.count - 1)
    }

    private func setEntries(_ entries: [ServerEntry], at i: Int) {
        playlists[i].trackIDs = entries.map { $0.id }
        playlists[i].trackKeys = Dictionary(entries.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        playlists[i].trackMeta = Dictionary(entries.map { ($0.id, $0.meta) }, uniquingKeysWith: { a, _ in a })
    }

    /// A phone entry's content key: its stored key, else resolved from the library.
    private func keyFor(_ id: String, in playlist: Playlist, library: LibraryStore) -> String? {
        if let k = playlist.trackKeys?[id] { return k }
        return library.tracksByID[id]?.contentKey
    }

    private func mergeOne(at i: Int, server s: ServerPlaylist, using library: LibraryStore) {
        let p = playlists[i]
        // Compare in the server's key space: a local song whose tags read differently
        // from its server twin's would otherwise look like two songs — duplicated in
        // the merge, or "removed" against a baseline stored under the other key.
        func canon(_ k: String) -> String { library.serverKeyByLocalKey[k] ?? k }
        var phoneKeyByID: [String: String] = [:]
        for id in p.trackIDs { if let k = keyFor(id, in: p, library: library) { phoneKeyByID[id] = canon(k) } }
        let phoneKeys = Set(phoneKeyByID.values)
        let serverEntryByKey = Dictionary(s.entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let serverKeys = Set(s.entries.map { $0.key })
        let base = Set((p.syncBaseline ?? []).map(canon))

        // A song stays unless it was in the baseline and one side genuinely removed it.
        let removed = base.subtracting(phoneKeys).union(base.subtracting(serverKeys))
        func keep(_ k: String) -> Bool { !removed.contains(k) }

        // Order: the phone's current order first, then server-only additions appended.
        var orderedKeys: [String] = []
        var seen = Set<String>()
        for id in p.trackIDs {
            guard let k = phoneKeyByID[id], keep(k), seen.insert(k).inserted else { continue }
            orderedKeys.append(k)
        }
        for e in s.entries where keep(e.key) && !seen.contains(e.key) {
            seen.insert(e.key)
            orderedKeys.append(e.key)
        }

        // Materialise each kept key, preferring the server-anchored entry so it streams.
        var phoneMetaByKey: [String: TrackMeta] = [:]
        for (id, k) in phoneKeyByID { if let tm = p.trackMeta?[id] { phoneMetaByKey[k] = tm } }
        var ids: [String] = []
        var keys: [String: String] = [:]
        var meta: [String: TrackMeta] = [:]
        for k in orderedKeys {
            if let e = serverEntryByKey[k] {
                ids.append(e.id); keys[e.id] = k; meta[e.id] = e.meta
            } else if let match = phoneKeyByID.first(where: { $0.value == k }) {
                ids.append(match.key); keys[match.key] = k
                if let tm = phoneMetaByKey[k] { meta[match.key] = tm }
            }
        }
        playlists[i].trackIDs = ids
        playlists[i].trackKeys = keys
        playlists[i].trackMeta = meta
        // The baseline is what BOTH sides hold. A phone-only song (no server copy, so it
        // can't be pushed) must stay out of it — otherwise the next merge reads "in the
        // baseline, missing on the server" as a server-side removal and drops it.
        playlists[i].syncBaseline = orderedKeys.filter { serverKeys.contains($0) || library.serverHasKey($0) }
    }

    /// After a successful push the server holds exactly the sent entries, so they become
    /// the merge baseline. Without this a song the phone added and the server later
    /// removed is indistinguishable from a fresh phone add, and would be pushed back.
    func markSynced(id: String, entryIDs: [String], using library: LibraryStore) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let p = playlists[i]
        playlists[i].syncBaseline = entryIDs.compactMap { keyFor($0, in: p, library: library) }
            .map { library.serverKeyByLocalKey[$0] ?? $0 }
        save()
    }

    func setServerID(_ serverID: String, forID id: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].serverID = serverID
        save()
    }

    /// Fold server-starred songs into Liked without dropping local likes.
    func mergeLikedFromServer(_ ids: [String]) {
        guard let i = playlists.firstIndex(where: { $0.kind == .liked }) else { return }
        var existing = playlists[i].trackIDs
        let have = Set(existing)
        for id in ids where !have.contains(id) { existing.insert(id, at: 0) }
        playlists[i].trackIDs = existing
        save()
    }

    // MARK: - Resolve
    /// Server songs some playlist points at that the phone's catalog doesn't hold —
    /// the entries that show as greyed placeholders until the catalog catches up.
    func serverEntriesMissing(from library: LibraryStore) -> Set<String> {
        var out = Set<String>()
        for p in playlists {
            for id in p.trackIDs where id.hasPrefix(SubsonicID.prefix) && !library.remoteIDs.contains(id) {
                out.insert(id)
            }
        }
        return out
    }

    func tracks(for playlist: Playlist, in library: LibraryStore) -> [Track] {
        // Resolve by content FIRST: the content index holds the best available source
        // for a song — the local file if it's on the device, otherwise the server copy
        // (which streams). So deleting a local file switches that track to streaming
        // instead of dropping it from the playlist. Fall back to a direct id lookup for
        // any entry that hasn't got a content key yet.
        playlist.trackIDs.compactMap { id in
            // A server-anchored entry whose file is also on the phone: that exact file
            // (matched by name), before any tag-based guess.
            if let t = library.localTwin(ofRemoteID: id) { return t }
            if let key = playlist.trackKeys?[id], let t = library.trackByContentKey[key] { return t }
            // Looser match (title + duration) when the content key missed because a tag
            // was read differently on each source — still resolves to the local copy,
            // since the merged index prefers it.
            if let m = playlist.trackMeta?[id], let t = library.trackByLooseKey[m.looseKey] { return t }
            if let t = library.tracksByID[id] { return t }
            // Not resolvable to a real source. Online, keep the song visible as a
            // placeholder built from its stored metadata (pending upload / schema-only);
            // offline, hide it so a playlist shows only what actually plays.
            if !library.effectiveOffline, let m = playlist.trackMeta?[id] {
                return Track(id: id, url: URL(fileURLWithPath: "/pending/\(id)"),
                             title: m.title, artist: m.artist, album: m.album,
                             trackNumber: 0, duration: m.duration, artworkData: nil,
                             dateAdded: .distantPast)
            }
            return nil
        }
    }
}
