import Foundation

/// An auto-generated "Made for You" mix.
struct Mix: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
}

/// Deterministic RNG so a mix is stable within a day instead of reshuffling on
/// every render.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

enum MixBuilder {
    /// Build mixes from the library + play history. All offline, no server.
    @MainActor
    static func mixes(tracks all: [Track], stats: PlayStatsStore, liked: [String]) -> [Mix] {
        guard all.count >= 8 else { return [] }   // not worth it for a tiny library
        var rng = SeededRNG(seed: daySeed())
        let likedSet = Set(liked)
        var out: [Mix] = []

        // Daily Mix — favourites-leaning pool, shuffled stably for the day.
        let ranked = all.sorted { score($0, stats: stats, liked: likedSet) > score($1, stats: stats, liked: likedSet) }
        var daily = Array(ranked.prefix(max(30, all.count / 2)))
        daily.shuffle(using: &rng)
        out.append(Mix(id: "daily", title: "Daily Mix", subtitle: "For you today",
                       tracks: Array(daily.prefix(30))))

        // Favorites Mix — your most-played artists.
        let topArtists = artistPlayCounts(all, stats: stats)
            .sorted { $0.value > $1.value }
            .prefix(3).filter { $0.value > 0 }.map(\.key)
        if !topArtists.isEmpty {
            var fav = all.filter { topArtists.contains($0.artist) }
            if fav.count >= 5 {
                fav.shuffle(using: &rng)
                out.append(Mix(id: "faves", title: "Favorites Mix",
                               subtitle: topArtists.joined(separator: ", "),
                               tracks: Array(fav.prefix(30))))
            }
        }

        // Fresh Finds — recently added, not yet played.
        let unplayed = all.filter { stats.playCount($0.id) == 0 }
            .sorted { $0.dateAdded > $1.dateAdded }
        if unplayed.count >= 5 {
            out.append(Mix(id: "fresh", title: "Fresh Finds",
                           subtitle: "Recently added, not yet played",
                           tracks: Array(unplayed.prefix(30))))
        }
        return out
    }

    @MainActor
    private static func score(_ t: Track, stats: PlayStatsStore, liked: Set<String>) -> Int {
        stats.playCount(t.id) * 2 + (liked.contains(t.id) ? 5 : 0)
    }

    @MainActor
    private static func artistPlayCounts(_ tracks: [Track], stats: PlayStatsStore) -> [String: Int] {
        var m: [String: Int] = [:]
        for t in tracks { m[t.artist, default: 0] += stats.playCount(t.id) }
        return m
    }

    private static func daySeed() -> UInt64 {
        UInt64(max(0, Int(Date().timeIntervalSince1970 / 86_400)))
    }
}
