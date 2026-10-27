import Foundation

enum PlaylistKind: String, Codable {
    case liked
    case podcasts
    case user
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
    // Server (Subsonic) playlist id this mirrors, if any. nil = local-only so far.
    var serverID: String? = nil

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
         trackKeys: [String: String]? = nil, serverID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trackIDs = trackIDs
        self.isPinned = isPinned
        self.details = details
        self.coverImageData = coverImageData
        self.trackKeys = trackKeys
        self.serverID = serverID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, trackIDs, isPinned, details, coverImageData, trackKeys, serverID
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
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID)
    }
}
