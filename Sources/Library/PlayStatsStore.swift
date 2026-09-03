import Foundation
import Combine

@MainActor
final class PlayStatsStore: ObservableObject {
    @Published private(set) var playCounts: [String: Int] = [:]
    @Published private(set) var recentlyPlayedIDs: [String] = []      // most-recent first
    @Published private(set) var lastPlayed: [String: Date] = [:]
    @Published private(set) var resumeTrackID: String?

    private let fileURL: URL
    private let maxRecent = 100

    struct Snapshot: Codable {
        var playCounts: [String: Int] = [:]
        var recentlyPlayedIDs: [String] = []
        var lastPlayed: [String: Date] = [:]
        var resumeTrackID: String? = nil
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
    }

    private func save() {
        let s = Snapshot(playCounts: playCounts, recentlyPlayedIDs: recentlyPlayedIDs,
                         lastPlayed: lastPlayed, resumeTrackID: resumeTrackID)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: fileURL, options: .atomic) }
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
}
