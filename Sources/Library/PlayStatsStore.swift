import Foundation
import Combine

@MainActor
final class PlayStatsStore: ObservableObject {
    @Published private(set) var playCounts: [String: Int] = [:]
    @Published private(set) var recentlyPlayedIDs: [String] = []      // most-recent first
    @Published private(set) var lastPlayed: [String: Date] = [:]
    @Published private(set) var resumeTrackID: String?

    // Per-playlist interaction stats (keyed by Playlist.id). An "interaction" is a
    // play from that playlist. Drives Home ordering (by count) + the Library list
    // ordering (by recency).
    @Published private(set) var playlistCounts: [String: Int] = [:]
    @Published private(set) var playlistLastPlayed: [String: Date] = [:]

    private let fileURL: URL
    private let maxRecent = 100

    struct Snapshot: Codable {
        var playCounts: [String: Int] = [:]
        var recentlyPlayedIDs: [String] = []
        var lastPlayed: [String: Date] = [:]
        var resumeTrackID: String? = nil
        // Optional so older playstats.json (written before these existed) still
        // decodes instead of throwing and wiping all play history.
        var playlistCounts: [String: Int]? = nil
        var playlistLastPlayed: [String: Date]? = nil
    }

    init(fileURL: URL? = nil) {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base.appendingPathComponent("playstats.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        playCounts = s.playCounts
        recentlyPlayedIDs = s.recentlyPlayedIDs
        lastPlayed = s.lastPlayed
        resumeTrackID = s.resumeTrackID
        playlistCounts = s.playlistCounts ?? [:]
        playlistLastPlayed = s.playlistLastPlayed ?? [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Current state as a Codable snapshot (used by backup/export).
    var snapshot: Snapshot {
        Snapshot(playCounts: playCounts, recentlyPlayedIDs: recentlyPlayedIDs,
                 lastPlayed: lastPlayed, resumeTrackID: resumeTrackID,
                 playlistCounts: playlistCounts, playlistLastPlayed: playlistLastPlayed)
    }

    /// Replace all stats from a restored backup.
    func restore(from s: Snapshot) {
        playCounts = s.playCounts
        recentlyPlayedIDs = s.recentlyPlayedIDs
        lastPlayed = s.lastPlayed
        resumeTrackID = s.resumeTrackID
        playlistCounts = s.playlistCounts ?? [:]
        playlistLastPlayed = s.playlistLastPlayed ?? [:]
        save()
    }

    func recordPlay(_ track: Track) {
        playCounts[track.id, default: 0] += 1
        lastPlayed[track.id] = Date()
        recentlyPlayedIDs.removeAll { $0 == track.id }
        recentlyPlayedIDs.insert(track.id, at: 0)
        if recentlyPlayedIDs.count > maxRecent {
            recentlyPlayedIDs = Array(recentlyPlayedIDs.prefix(maxRecent))
        }
        resumeTrackID = track.id
        save()
    }

    func playCount(_ id: String) -> Int { playCounts[id] ?? 0 }

    func recentlyPlayed(from tracks: [Track], limit: Int = 50) -> [Track] {
        let map = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Array(recentlyPlayedIDs.compactMap { map[$0] }.prefix(limit))
    }

    func mostPlayed(from tracks: [Track], limit: Int = 50) -> [Track] {
        Array(tracks.filter { playCount($0.id) > 0 }
            .sorted { playCount($0.id) > playCount($1.id) }
            .prefix(limit))
    }

    // MARK: - Playlist interactions
    func recordPlaylistInteraction(_ id: String) {
        playlistCounts[id, default: 0] += 1
        playlistLastPlayed[id] = Date()
        save()
    }

    func playlistInteractions(_ id: String) -> Int { playlistCounts[id] ?? 0 }
    func playlistLastPlayedDate(_ id: String) -> Date? { playlistLastPlayed[id] }

    /// Playlists ordered by interaction count, most first. Stable: equal counts
    /// keep the input order, so the caller's base order (e.g. pinned-first) breaks
    /// ties and nothing shuffles around before anything has been played.
    func byInteractions(_ list: [Playlist]) -> [Playlist] {
        list.enumerated().sorted {
            let a = playlistInteractions($0.element.id), b = playlistInteractions($1.element.id)
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
    }

    /// Playlists ordered by last played, most recent first; never-played ones keep
    /// the input order at the end.
    func byLastPlayed(_ list: [Playlist]) -> [Playlist] {
        list.enumerated().sorted {
            switch (playlistLastPlayedDate($0.element.id), playlistLastPlayedDate($1.element.id)) {
            case let (x?, y?): return x == y ? $0.offset < $1.offset : x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return $0.offset < $1.offset
            }
        }.map(\.element)
    }
}
