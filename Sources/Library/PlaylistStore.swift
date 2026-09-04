import Foundation
import Combine

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
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
        seedDemoIfNeeded()
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

    // MARK: - Ordering / pinning
    var orderedPlaylists: [Playlist] {
        playlists.filter { $0.isPinned } + playlists.filter { !$0.isPinned }
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
        }
        save()
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

    // MARK: - Resolve
    func tracks(for playlist: Playlist, in library: LibraryStore) -> [Track] {
        let map = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.trackIDs.compactMap { map[$0] }
    }
}
