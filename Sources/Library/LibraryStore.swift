import Foundation
import AVFoundation
import UIKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var tracksByID: [String: Track] = [:]
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [ArtistGroup] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isFetchingArtwork = false

    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "aif", "aiff", "caf", "m4b", "ogg"
    ]

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Scanning
    /// Incremental, cache-backed scan. On launch the cached library from the last
    /// session shows instantly; then only NEW files are parsed and deleted ones
    /// drop away. `force: true` re-parses everything (Settings → Rescan).
    func scan(force: Bool = false) async {
        isScanning = true
        defer { isScanning = false }

        // Instant: paint last session's library from the cache before touching disk.
        if !force, tracks.isEmpty, let cached = await readCache() {
            tracks = cached
            rebuildCollections()
        }

        // Reuse already-known tracks by id so we don't re-parse them; only new
        // files hit makeTrack. Rebuilding from the live file list also drops any
        // tracks whose files are gone.
        let known = force ? [:] : Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let urls = audioFileURLs()
        var result: [Track] = []
        var seenIDs = Set<String>()
        for url in urls {
            let id = url.lastPathComponent
            guard seenIDs.insert(id).inserted else { continue }   // dedup same-named files
            if let c = known[id] {
                // Known file — keep cached metadata, but point at the CURRENT url
                // (the container path changes on reinstall).
                result.append(Track(id: c.id, url: url, title: c.title, artist: c.artist,
                                    album: c.album, albumArtist: c.albumArtist, trackNumber: c.trackNumber,
                                    discNumber: c.discNumber, duration: c.duration,
                                    artworkData: c.artworkData, dateAdded: c.dateAdded, lyrics: c.lyrics))
            } else if let track = await makeTrack(from: url) {
                result.append(track)
            }
        }
        result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        #if targetEnvironment(simulator)
        if result.isEmpty { result = Self.demoTracks() }
        #endif
        tracks = result
        rebuildCollections()
        saveCache(result)
    }

    // MARK: - Library cache (instant launch; survives sessions)
    private var cacheURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? documentsURL
        return base.appendingPathComponent("library-cache.json")
    }

    private func readCache() async -> [Track]? {
        let url = cacheURL
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode([Track].self, from: data)
        }.value
    }

    private func saveCache(_ tracks: [Track]) {
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(tracks) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func audioFileURLs() -> [URL] {
        // Explicit iterative deep walk: drill through folders-within-folders to
        // any depth. Each directory is read independently, so one unreadable
        // subfolder is skipped instead of silently halting the whole scan (the
        // failure mode of a bare enumerator with no error handler).
        let fm = FileManager.default
        var found: [URL] = []
        var stack = [documentsURL]
        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    stack.append(url)
                } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                }
            }
        }
        return found
    }

    private func makeTrack(from url: URL) async -> Track? {
        let asset = AVURLAsset(url: url)
        let ext = url.pathExtension.lowercased()
        let fileBaseName = url.deletingPathExtension().lastPathComponent

        var title = fileBaseName
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var albumArtist: String?
        var trackNumber = 0
        var discNumber = 0
        var duration: Double = 0
        var artworkData: Data?
        var lyrics: String?
        var dateAdded = Date.distantPast

        if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            dateAdded = values.creationDate ?? values.contentModificationDate ?? .distantPast
        }

        if let cmDuration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(cmDuration)
            if secs.isFinite && secs > 0 { duration = secs }
        }

        // AVFoundation reads MP3/MP4/etc tags — but not FLAC Vorbis comments.
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                case .commonKeyArtist, .commonKeyAuthor, .commonKeyCreator:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
                case .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { album = value }
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        artworkData = Self.thumbnail(from: data)
                    }
                default:
                    break
                }
            }
        }

        // FLAC: parse Vorbis comments + embedded artwork ourselves (off the main
        // actor so a big library doesn't stall the UI while scanning).
        if ext == "flac",
           let tags = await Task.detached(priority: .utility, operation: { FLACMetadata.read(url: url) }).value {
            if let t = tags.title, !t.isEmpty { title = t }
            if let a = tags.artist, !a.isEmpty { artist = a }
            if let al = tags.album, !al.isEmpty { album = al }
            if let aa = tags.albumArtist, !aa.isEmpty { albumArtist = aa }
            if let n = tags.trackNumber { trackNumber = n }
            if let d = tags.discNumber { discNumber = d }
            if let ly = tags.lyrics, !ly.isEmpty { lyrics = ly }
            if artworkData == nil, let pic = tags.artwork { artworkData = Self.thumbnail(from: pic) }
        }

        // Fallback for untagged files named "Artist - Title".
        if artist == "Unknown Artist", let range = fileBaseName.range(of: " - ") {
            let a = fileBaseName[fileBaseName.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let t = fileBaseName[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !a.isEmpty, !t.isEmpty {
                artist = a
                if title == fileBaseName { title = t }   // only if tags gave no real title
            }
        }

        return Track(
            id: url.lastPathComponent,
            url: url,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            artworkData: artworkData,
            dateAdded: dateAdded,
            lyrics: lyrics
        )
    }

    /// Downscale embedded artwork so a large library doesn't blow up memory.
    static func thumbnail(from data: Data, maxDimension: CGFloat = 600) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else {
            return image.jpegData(compressionQuality: 0.85) ?? data
        }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: 0.85)
    }

    #if targetEnvironment(simulator)
    /// Demo library so the app is populated when run in the iOS Simulator (e.g. Appetize).
    static func demoTracks() -> [Track] {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "wav") else { return [] }
        let seed: [(String, String, String)] = [
            ("Midnight Drive", "The Violets", "Neon Nights"),
            ("Afterglow", "The Violets", "Neon Nights"),
            ("Coastline", "Marlowe", "Saltwater"),
            ("Undertow", "Marlowe", "Saltwater"),
            ("Paper Planes", "Kite", "Field Notes"),
            ("Ferris Wheel", "Kite", "Field Notes"),
        ]
        return seed.enumerated().map { index, meta in
            Track(id: "demo-\(index)", url: url, title: meta.0, artist: meta.1, album: meta.2,
                  trackNumber: index, duration: 4,
                  artworkData: demoArtwork(hue: Double(index) / Double(seed.count)),
                  dateAdded: Date().addingTimeInterval(Double(-index) * 3600))
        }
    }

    static func demoArtwork(hue: Double) -> Data? {
        let size = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let c1 = UIColor(hue: CGFloat(hue.truncatingRemainder(dividingBy: 1.0)),
                             saturation: 0.55, brightness: 0.95, alpha: 1)
            let c2 = UIColor(hue: CGFloat((hue + 0.12).truncatingRemainder(dividingBy: 1.0)),
                             saturation: 0.70, brightness: 0.60, alpha: 1)
            let colors = [c1.cgColor, c2.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient, start: .zero,
                    end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }
    #endif

    // MARK: - Collections
    /// Resolve stored recent-search items against the live library for rendering.
    /// Unresolvable ids (deleted files, etc.) are skipped, not shown as dead rows.
    func resolve(_ items: [RecentSearchItem]) -> [ResolvedRecent] {
        items.compactMap { item in
            switch item {
            case .track(let id):
                return tracksByID[id].map(ResolvedRecent.track)
            case .query(let text):
                return .query(text)
            }
        }
    }

    /// Tracks to keep playing with when the queue runs out (autoplay / radio):
    /// same artist first, then same album, then a shuffled spread of the rest.
    func autoplaySuggestions(after track: Track, excluding: Set<String>, limit: Int = 25) -> [Track] {
        var used = excluding
        var picked: [Track] = []
        func take(_ candidates: [Track]) {
            for t in candidates where !used.contains(t.id) {
                used.insert(t.id)
                picked.append(t)
                if picked.count >= limit { break }
            }
        }
        take(tracks.filter { $0.artist == track.artist })
        if picked.count < limit { take(tracks.filter { $0.album == track.album }) }
        if picked.count < limit { take(tracks.shuffled()) }
        return picked
    }

    /// Fill in missing album artwork from the network (user-initiated). Fetches
    /// once per album, applies all updates in one pass, and persists to the cache.
    func fetchMissingArtwork() async {
        guard !isFetchingArtwork else { return }
        isFetchingArtwork = true
        defer { isFetchingArtwork = false }

        var artByAlbum: [String: Data] = [:]   // fetched thumbnail per album key
        var triedAlbums = Set<String>()
        var updates: [String: Data] = [:]      // track id -> thumbnail

        for t in tracks where t.artworkData == nil {
            let key = "\(t.albumArtist ?? t.artist)\u{1}\(t.album)"
            if let art = artByAlbum[key] {
                updates[t.id] = art
            } else if !triedAlbums.contains(key) {
                triedAlbums.insert(key)
                if let raw = await ArtworkFetcher.fetchRaw(artist: t.albumArtist ?? t.artist, album: t.album),
                   let thumb = Self.thumbnail(from: raw) {
                    artByAlbum[key] = thumb
                    updates[t.id] = thumb
                }
            }
        }
        guard !updates.isEmpty else { return }
        tracks = tracks.map { tk in
            guard let art = updates[tk.id] else { return tk }
            var m = tk; m.artworkData = art; return m
        }
        rebuildCollections()
        saveCache(tracks)
    }

    /// The album / artist a track belongs to (for "Go to Album/Artist").
    func album(for track: Track) -> Album? {
        albums.first { $0.tracks.contains { $0.id == track.id } }
    }
    func artist(for track: Track) -> ArtistGroup? {
        artists.first { $0.name == track.artist }
    }

    private func rebuildCollections() {
        tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Group by album + album-artist so compilations stay one album and
        // multi-performer albums don't fragment. Order within an album by (disc,
        // track) so multi-disc sets play in the right sequence.
        let byAlbum = Dictionary(grouping: tracks) { "\($0.album)\u{1}\($0.albumArtist ?? $0.artist)" }
        albums = byAlbum.map { key, group in
            let sorted = group.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return Album(
                id: key,
                title: group.first?.album ?? "Unknown Album",
                artist: group.first?.albumArtist ?? group.first?.artist ?? "Unknown Artist",
                tracks: sorted
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let byArtist = Dictionary(grouping: tracks) { $0.artist }
        artists = byArtist.map { name, group in
            ArtistGroup(
                id: name,
                name: name,
                tracks: group.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Import
    @discardableResult
    func importFiles(_ urls: [URL]) -> [String] {
        let fm = FileManager.default
        var importedIDs: [String] = []
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue {
                // Folder: import every audio file inside it (recursively).
                if let en = fm.enumerator(at: source, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles]) {
                    for case let file as URL in en
                    where audioExtensions.contains(file.pathExtension.lowercased()) {
                        if let id = copyIntoLibrary(file) { importedIDs.append(id) }
                    }
                }
            } else if audioExtensions.contains(source.pathExtension.lowercased()) {
                if let id = copyIntoLibrary(source) { importedIDs.append(id) }
            }
        }
        Task { await scan() }
        return importedIDs
    }

    private func copyIntoLibrary(_ source: URL) -> String? {
        let fm = FileManager.default
        // Already inside the app's Music folder (even in a subfolder)? It's already
        // in the library — reference it in place, never copy. Only files from
        // outside (iCloud Drive, Downloads, …) get copied in. This is what stops
        // "import from the Music folder" leaving a second flat copy on disk.
        let docsPath = documentsURL.resolvingSymlinksInPath().path
        if source.resolvingSymlinksInPath().path.hasPrefix(docsPath + "/") {
            return source.lastPathComponent
        }
        let name = source.lastPathComponent
        var destination = documentsURL.appendingPathComponent(name)
        let srcSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if fm.fileExists(atPath: destination.path) {
            let dstSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            // Same name + same size → the same file is already in the library.
            // Reuse it so importing a song into a second playlist doesn't duplicate
            // it (both playlists just share the one id). Previously we overwrote,
            // which silently replaced a different same-named song with this one.
            if let s = srcSize, s == dstSize { return destination.lastPathComponent }
            // Same name, genuinely different file → keep both under a unique name.
            destination = uniqueDestination(for: name)
        }
        do {
            try fm.copyItem(at: source, to: destination)
            return destination.lastPathComponent
        } catch {
            print("Import failed for \(name): \(error)")
            return nil
        }
    }

    private func uniqueDestination(for name: String) -> URL {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = documentsURL.appendingPathComponent(
                ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        Task { await scan() }
    }
}
