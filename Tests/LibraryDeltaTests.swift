import XCTest
@testable import Music

/// The song-count delta: a diff of the server's whole song list, so a track added to
/// an album the server already had still reaches the phone.
@MainActor
final class LibraryDeltaTests: XCTestCase {

    private func remote(_ id: String, title: String, album: String) -> Track {
        Track(id: SubsonicID.prefix + id, url: URL(fileURLWithPath: "/cache/\(id).flac"),
              title: title, artist: "Hiroyuki Sawano", album: album, trackNumber: 1,
              duration: 200, artworkData: nil, dateAdded: Date(),
              sourcePath: "/music/aot/\(title).flac")
    }

    func testAddsSongToKnownAlbumAndDropsDeleted() {
        let lib = LibraryStore()
        let a = remote("a", title: "Vogel im Käfig", album: "AOT OST")
        let b = remote("b", title: "XL-TT", album: "AOT OST")
        lib.mergeRemote([a, b], persist: false)

        // Same album as a and b: the old newest-album walk never reached this one.
        let c = remote("c", title: "Call Your Name", album: "AOT OST")
        lib.applyRemoteDelta(added: [c], removedIDs: [a.id], persist: false)

        XCTAssertEqual(Set(lib.remoteTracks.map(\.id)), [b.id, c.id])
        XCTAssertTrue(lib.tracks.contains { $0.id == c.id })
        XCTAssertFalse(lib.tracks.contains { $0.id == a.id })
    }

    // The gift / Mvt. 5 case: the playlist arrived, the song didn't, and the song count
    // was already recorded — only the missing entry can tell the sync to diff.
    func testPlaylistEntryMissingFromCatalogIsReported() {
        let lib = LibraryStore()
        let known = remote("k", title: "Schmetterling", album: "Tokyo Ghoul OST")
        lib.mergeRemote([known], persist: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pl-\(UUID().uuidString).json")
        let store = PlaylistStore(fileURL: url)
        let p = store.createPlaylist(name: "gift")
        let mvt5 = remote("m", title: "Mvt. 5 \"Schmetterling\"", album: "Tokyo Ghoul:re OST")
        store.add(known, to: p.id)
        store.add(mvt5, to: p.id)
        store.add(Track(id: "/docs/local.flac", url: URL(fileURLWithPath: "/docs/local.flac"),
                        title: "Local", artist: "A", album: "B", trackNumber: 0,
                        duration: 1, artworkData: nil, dateAdded: Date()), to: p.id)

        XCTAssertEqual(store.serverEntriesMissing(from: lib), [mvt5.id])   // phone-only entries never count

        lib.applyRemoteDelta(added: [mvt5], removedIDs: [], persist: false)
        XCTAssertTrue(store.serverEntriesMissing(from: lib).isEmpty)
    }

    func testKeepsArtworkOfSongsAlreadyHeld() {
        let lib = LibraryStore()
        let b = remote("b", title: "XL-TT", album: "AOT OST")
        lib.mergeRemote([b], persist: false)
        lib.applyRemoteArtwork([b.id: Data([1, 2, 3])])

        // The diff hands back a fresh copy of b with no artwork; it must not replace ours.
        lib.applyRemoteDelta(added: [b, remote("c", title: "Call Your Name", album: "AOT OST")],
                             removedIDs: [], persist: false)

        XCTAssertEqual(lib.remoteTracks.first { $0.id == b.id }?.artworkData, Data([1, 2, 3]))
        XCTAssertEqual(lib.remoteTracks.count, 2)
    }
}
