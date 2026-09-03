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
    var trackIDs: [String]              // Track.id == file path
    var isPinned: Bool = false
    var details: String = ""            // user description
    var coverImageData: Data? = nil     // custom cover (user playlists)

    var isSystem: Bool { kind != .user }

    var systemIcon: String {
        switch kind {
        case .liked: return "heart.fill"
        case .podcasts: return "mic.fill"
        case .user: return "music.note.list"
        }
    }

    init(id: String, name: String, kind: PlaylistKind, trackIDs: [String],
         isPinned: Bool = false, details: String = "", coverImageData: Data? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trackIDs = trackIDs
        self.isPinned = isPinned
        self.details = details
        self.coverImageData = coverImageData
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, trackIDs, isPinned, details, coverImageData
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
    }
}
