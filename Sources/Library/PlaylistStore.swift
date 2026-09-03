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
    }

    // MARK: - Persistence
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
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
            guard playlists.filter({ $0.isPinned }).count < 4 else { return }
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
