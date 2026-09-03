import Foundation
import AVFoundation
import UIKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [ArtistGroup] = []
    @Published private(set) var isScanning = false

    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "aif", "aiff", "caf", "m4b", "ogg"
    ]

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Scanning
    func scan() async {
        isScanning = true
        defer { isScanning = false }

        let urls = audioFileURLs()
        var result: [Track] = []
        for url in urls {
            if let track = await makeTrack(from: url) {
                result.append(track)
            }
        }
        result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        #if targetEnvironment(simulator)
        if result.isEmpty { result = Self.demoTracks() }
        #endif
        tracks = result
        rebuildCollections()
    }

    private func audioFileURLs() -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        if let enumerator = fm.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if audioExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                }
            }
        }
        return found
    }

    private func makeTrack(from url: URL) async -> Track? {
        let asset = AVURLAsset(url: url)

        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var duration: Double = 0
        var artworkData: Data?
        var dateAdded = Date.distantPast

        if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            dateAdded = values.creationDate ?? values.contentModificationDate ?? .distantPast
        }

        if let cmDuration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(cmDuration)
            if secs.isFinite && secs > 0 { duration = secs }
        }

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

        return Track(
            id: url.path,
            url: url,
            title: title,
            artist: artist,
            album: album,
            trackNumber: 0,
            duration: duration,
            artworkData: artworkData,
            dateAdded: dateAdded
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
    private func rebuildCollections() {
        let byAlbum = Dictionary(grouping: tracks) { "\($0.album)\u{1}\($0.artist)" }
        albums = byAlbum.map { key, group in
            let sorted = group.sorted {
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return Album(
                id: key,
                title: group.first?.album ?? "Unknown Album",
                artist: group.first?.artist ?? "Unknown Artist",
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

            let destination = documentsURL.appendingPathComponent(source.lastPathComponent)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                importedIDs.append(destination.path)
            } catch {
                print("Import failed for \(source.lastPathComponent): \(error)")
            }
        }
        Task { await scan() }
        return importedIDs
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        Task { await scan() }
    }
}
