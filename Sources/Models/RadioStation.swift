import Foundation

/// An internet radio station: one saved on the Navidrome server (serverID), one found
/// in the Radio Browser directory (browserUUID), or both once a found station is saved.
struct RadioStation: Identifiable, Hashable, Codable {
    var name: String
    var streamURL: URL
    var homepage: URL? = nil
    var favicon: URL? = nil
    var country: String = ""
    var state: String = ""
    var tags: String = ""            // comma-separated, as the directory gives them
    var codec: String = ""
    var bitrate: Int = 0
    var serverID: String? = nil      // Navidrome's id once saved there
    var browserUUID: String? = nil   // Radio Browser's id (play counts are reported to it)

    /// Saved and found copies of one station match by stream address.
    var id: String { streamURL.absoluteString }

    /// "Dallas, Texas · oldies" — where it is and what it plays, as far as known.
    var subtitle: String {
        let place = [state, country].filter { !$0.isEmpty }.joined(separator: ", ")
        let genre = tags.split(separator: ",").prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ", ")
        return [place, genre].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "AAC 128" — the stream as the station broadcasts it; nothing when unknown.
    var formatLabel: String? {
        let c = codec.uppercased().replacingOccurrences(of: "AAC+", with: "AAC")
        guard !c.isEmpty || bitrate > 0 else { return nil }
        return [c, bitrate > 0 ? String(bitrate) : ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A station plays through the player as a live track: no duration, never cached.
    static let trackPrefix = "radio:"

    func asTrack(artwork: Data?) -> Track {
        Track(id: Self.trackPrefix + id, url: streamURL, title: name,
              artist: subtitle.isEmpty ? "Radio" : subtitle,
              album: formatLabel ?? "Radio", trackNumber: 0, duration: 0,
              artworkData: artwork, dateAdded: Date())
    }
}

extension Track {
    var isRadio: Bool { id.hasPrefix(RadioStation.trackPrefix) }
}
