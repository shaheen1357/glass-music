import Foundation
import UIKit

struct Track: Identifiable, Hashable, Codable, Sendable {
    let id: String          // stable id = file path
    let url: URL
    var title: String
    var artist: String
    var album: String
    var albumArtist: String? = nil   // for compilation / multi-artist album grouping
    var trackNumber: Int
    var discNumber: Int = 0
    var duration: Double
    var artworkData: Data?
    var dateAdded: Date
    var lyrics: String? = nil

    var artwork: UIImage? {
        guard let artworkData else { return nil }
        return UIImage(data: artworkData)
    }

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Track {
    enum CodingKeys: String, CodingKey {
        case id, url, title, artist, album, albumArtist, trackNumber, discNumber, duration, artworkData, dateAdded, lyrics
    }
    // Tolerant decode: fields added in later versions default when absent, so an
    // older library-cache.json still loads instead of forcing a full rescan.
    // (Declared in an extension so the memberwise init is preserved.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        artworkData = try c.decodeIfPresent(Data.self, forKey: .artworkData)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? .distantPast
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    var tracks: [Track]
    var artworkData: Data? {
        tracks.first(where: { $0.artworkData != nil })?.artworkData
    }
    var dateAdded: Date {
        tracks.map { $0.dateAdded }.max() ?? .distantPast
    }
}

struct ArtistGroup: Identifiable, Hashable {
    let id: String
    let name: String
    var tracks: [Track]
    var albumCount: Int { Set(tracks.map { $0.album }).count }
}
