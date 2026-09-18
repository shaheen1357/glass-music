import Foundation

/// Minimal FLAC metadata reader.
///
/// AVFoundation plays FLAC but does **not** expose its Vorbis-comment tags or
/// embedded artwork, so untagged-looking files show as "Unknown Artist". This
/// walks the FLAC metadata blocks directly to pull TITLE/ARTIST/ALBUM/track
/// number and the first PICTURE block. Only metadata blocks (at the start of
/// the file) are read — never the audio frames — so it stays cheap even for
/// large hi-res files.
enum FLACMetadata {
    struct Tags: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?
        var artwork: Data?
        var lyrics: String?
    }

    static func read(url: URL) -> Tags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 4),
              magic == Data("fLaC".utf8) else { return nil }

        var tags = Tags()
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let isLast = (header[header.startIndex] & 0x80) != 0
            let type = header[header.startIndex] & 0x7F
            let length = (Int(header[header.startIndex + 1]) << 16)
                | (Int(header[header.startIndex + 2]) << 8)
                | Int(header[header.startIndex + 3])
            guard length >= 0, length <= 50_000_000 else { break }
            guard let block = try? handle.read(upToCount: length), block.count == length else { break }

            switch type {
            case 4: parseVorbisComment(block, into: &tags)   // VORBIS_COMMENT
            case 6: if tags.artwork == nil { tags.artwork = parsePicture(block) }  // PICTURE
            default: break
            }
            if isLast { break }
        }
        return tags
    }

    // MARK: - Blocks

    private static func parseVorbisComment(_ data: Data, into tags: inout Tags) {
        var i = data.startIndex
        func uint32LE() -> Int? {
            guard i + 4 <= data.endIndex else { return nil }
            let v = Int(data[i]) | (Int(data[i + 1]) << 8)
                | (Int(data[i + 2]) << 16) | (Int(data[i + 3]) << 24)
            i += 4
            return v
        }
        guard let vendorLen = uint32LE(), i + vendorLen <= data.endIndex else { return }
        i += vendorLen                                     // skip vendor string
        guard let count = uint32LE() else { return }

        for _ in 0..<count {
            guard let len = uint32LE(), len >= 0, i + len <= data.endIndex else { return }
            let field = data.subdata(in: i..<(i + len))
            i += len
            guard let comment = String(data: field, encoding: .utf8),
                  let eq = comment.firstIndex(of: "=") else { continue }
            let key = comment[comment.startIndex..<eq].uppercased()
            let value = String(comment[comment.index(after: eq)...])
            guard !value.isEmpty else { continue }
            switch key {
            case "TITLE": tags.title = value
            // Track ARTIST wins; album/main artist only fill in when it's absent
            // (so compilations still show the performer, not the album artist).
            case "ARTIST": tags.artist = value
            case "ALBUMARTIST", "ALBUM ARTIST", "MAIN_ARTIST":
                tags.albumArtist = value
                if tags.artist == nil { tags.artist = value }
            case "ALBUM": tags.album = value
            case "TRACKNUMBER":
                let num = value.split(separator: "/").first.map(String.init) ?? value
                tags.trackNumber = Int(num.trimmingCharacters(in: .whitespaces))
            case "DISCNUMBER", "DISC":
                let num = value.split(separator: "/").first.map(String.init) ?? value
                tags.discNumber = Int(num.trimmingCharacters(in: .whitespaces))
            case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS":
                if tags.lyrics == nil { tags.lyrics = value }
            default: break
            }
        }
    }

    private static func parsePicture(_ data: Data) -> Data? {
        var i = data.startIndex
        func uint32BE() -> Int? {
            guard i + 4 <= data.endIndex else { return nil }
            let v = (Int(data[i]) << 24) | (Int(data[i + 1]) << 16)
                | (Int(data[i + 2]) << 8) | Int(data[i + 3])
            i += 4
            return v
        }
        guard uint32BE() != nil else { return nil }                    // picture type
        guard let mimeLen = uint32BE(), i + mimeLen <= data.endIndex else { return nil }
        i += mimeLen                                                    // MIME string
        guard let descLen = uint32BE(), i + descLen <= data.endIndex else { return nil }
        i += descLen                                                    // description
        guard uint32BE() != nil, uint32BE() != nil,                     // width, height
              uint32BE() != nil, uint32BE() != nil else { return nil }  // depth, colors
        guard let picLen = uint32BE(), picLen > 0, i + picLen <= data.endIndex else { return nil }
        return data.subdata(in: i..<(i + picLen))
    }
}
