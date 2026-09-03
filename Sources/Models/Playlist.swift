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
    var trackIDs: [String]      // Track.id == file path
    var isPinned: Bool = false

    var isSystem: Bool { kind != .user }

    var systemIcon: String {
        switch kind {
        case .liked: return "heart.fill"
        case .podcasts: return "mic.fill"
        case .user: return "music.note.list"
        }
    }
}
