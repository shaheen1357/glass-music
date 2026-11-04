import Foundation

/// Shuffle that feels random rather than being random. Plain shuffling on a library
/// built from album and soundtrack folders plays three tracks of one score in a row
/// and repeats what you heard an hour ago. This:
///   - keeps only songs that can play right now (offline: what's on the phone),
///   - weights the draw: liked and often-played songs a little up, songs you've
///     never played a little up (your own discovery), anything played in the last
///     day well down — so it drifts to the back, it doesn't vanish,
///   - then spreads the order so the same artist or album doesn't come back to back.
/// All on the phone, from play history Glass already keeps. No server involved.
enum SmartShuffle {
    @MainActor
    static func order(_ tracks: [Track], stats: PlayStatsStore,
                      isLiked: (Track) -> Bool, canPlay: (Track) -> Bool,
                      now: Date = Date()) -> [Track] {
        let pool = tracks.filter(canPlay)
        guard pool.count > 2 else { return pool.shuffled() }

        // Weighted random order (Efraimidis–Spirakis): key = u^(1/w), highest first.
        let keyed: [(Track, Double)] = pool.map { t in
            var w = 1.0
            if isLiked(t) { w += 1.0 }
            let plays = stats.playCounts[t.id] ?? 0
            w += Double(min(plays, 10)) * 0.08
            if plays == 0 { w *= 1.3 }
            if let last = stats.lastPlayed[t.id], now.timeIntervalSince(last) < 24 * 3600 { w *= 0.25 }
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1)
            return (t, pow(u, 1 / w))
        }
        var remaining = keyed.sorted { $0.1 > $1.1 }.map(\.0)

        // Spread: take the best-ranked song that doesn't repeat the last artist or
        // album; if every remaining song does, take the best one anyway.
        var out: [Track] = []
        out.reserveCapacity(remaining.count)
        while !remaining.isEmpty {
            let recentArtists = Set(out.suffix(2).map { $0.artist.lowercased() })
            let lastAlbum = out.last?.album.lowercased()
            let pick = remaining.prefix(40).firstIndex {
                !recentArtists.contains($0.artist.lowercased()) && $0.album.lowercased() != lastAlbum
            } ?? 0
            out.append(remaining.remove(at: pick))
        }
        return out
    }
}
