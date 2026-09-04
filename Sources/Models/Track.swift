import Foundation
import UIKit

struct Track: Identifiable, Hashable {
    let id: String          // stable id = file path
    let url: URL
    var title: String
    var artist: String
    var album: String
    var trackNumber: Int
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
