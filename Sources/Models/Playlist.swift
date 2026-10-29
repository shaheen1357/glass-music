import Foundation

enum PlaylistKind: String, Codable {
    case liked
    case podcasts
    case user
}

/// A playlist entry's display metadata, kept so a song still shows its name and artist
/// when it resolves to neither a local file nor the server catalog yet — the
/// "schema + metadata pointing at the server" that a pending-upload song needs.
struct TrackMeta: Codable, Hashable {
    var title: String
    var artist: String
    var album: String
    var duration: Double

    /// Must match Track.contentKey exactly, so a playlist entry can be re-keyed from its
    /// stored metadata (artist + album + title, no track/disc numbers).
    var contentKey: String {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return "\(norm(artist))\u{1}\(norm(album))\u{1}\(norm(title))"
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var kind: PlaylistKind
    var trackIDs: [String]              // Track.id (local = file path, remote = "subsonic:<id>")
    var isPinned: Bool = false
    var details: String = ""            // user description
    var coverImageData: Data? = nil     // custom cover (user playlists)
    // Content key per stored track id, so an entry survives its local file being
    // deleted — the same song is found from another source by content.
    var trackKeys: [String: String]? = nil
    // Display metadata per stored track id, so an entry still shows (greyed, pending)
    // when it's neither on the device nor on the server yet.
    var trackMeta: [String: TrackMeta]? = nil
    // Server (Subsonic) playlist id this mirrors, if any. nil = local-only so far.
    var serverID: String? = nil
    // The set of content keys as of the last successful sync — the baseline for a
    // three-way merge, so an add on the phone and an add on the server both survive
    // and a real removal on either side is honoured.
    var syncBaseline: [String]? = nil

    var isSystem: Bool { kind != .user }

    var systemIcon: String {
        switch kind {
        case .liked: return "heart.fill"
        case .podcasts: return "mic.fill"
        case .user: return "music.note.list"
        }
    }

    init(id: String, name: String, kind: PlaylistKind, trackIDs: [String],
         isPinned: Bool = false, details: String = "", coverImageData: Data? = nil,
         trackKeys: [String: String]? = nil, trackMeta: [String: TrackMeta]? = nil,
         serverID: String? = nil, syncBaseline: [String]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trackIDs = trackIDs
        self.isPinned = isPinned
        self.details = details
        self.coverImageData = coverImageData
        self.trackKeys = trackKeys
        self.trackMeta = trackMeta
        self.serverID = serverID
        self.syncBaseline = syncBaseline
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, trackIDs, isPinned, details, coverImageData
        case trackKeys, trackMeta, serverID, syncBaseline
    }

    // Tolerant decoder: missing keys fall back to defaults so old saved data
    // (written before a field existed) still loads instead of being wiped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(PlaylistKind.self, forKey: .kind)
        trackIDs = try c.decodeIfPresent([String].self, forKey: .trackIDs) ?? []
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        coverImageData = try c.decodeIfPresent(Data.self, forKey: .coverImageData)
        trackKeys = try c.decodeIfPresent([String: String].self, forKey: .trackKeys)
        trackMeta = try c.decodeIfPresent([String: TrackMeta].self, forKey: .trackMeta)
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID)
        syncBaseline = try c.decodeIfPresent([String].self, forKey: .syncBaseline)
    }
}
