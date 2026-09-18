import Foundation

/// A single-file backup of everything the user curated that CANNOT be rebuilt from
/// the audio files themselves: playlists (incl. Liked Songs) and play history/stats.
/// The music files aren't included — the library rebuilds itself from the Music
/// folder on every launch. This is what survives a reinstall or a move to a new phone.
struct MusicBackup: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()
    var playlists: [Playlist]
    var stats: PlayStatsStore.Snapshot
}

enum BackupService {
    /// Encode the current library curation to a temp file and return its URL for
    /// sharing. Returns nil only if encoding fails.
    @MainActor
    static func makeFile(playlists: PlaylistStore, stats: PlayStatsStore) -> URL? {
        let backup = MusicBackup(playlists: playlists.playlists, stats: stats.snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(backup) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Music-Backup-\(stamp()).json")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// Read a backup file and apply it, replacing playlists + stats. Returns false
    /// if the file can't be read or isn't a valid backup.
    @MainActor
    @discardableResult
    static func restore(from url: URL, playlists: PlaylistStore, stats: PlayStatsStore) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(MusicBackup.self, from: data) else { return false }
        playlists.replaceAll(with: backup.playlists)
        stats.restore(from: backup.stats)
        return true
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }
}
