import XCTest
@testable import Music

@MainActor
final class PlaylistStoreTests: XCTestCase {

    private func makeStore() -> PlaylistStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-\(UUID().uuidString).json")
        return PlaylistStore(fileURL: url)
    }

    private func track(_ id: String, artist: String = "A", album: String = "B") -> Track {
        Track(id: id, url: URL(fileURLWithPath: "/tmp/\(id).flac"),
              title: id, artist: artist, album: album, trackNumber: 0,
              duration: 100, artworkData: nil, dateAdded: Date())
    }

    func testSystemPlaylistsExist() {
        let store = makeStore()
        XCTAssertTrue(store.playlists.contains { $0.kind == .liked })
        XCTAssertTrue(store.playlists.contains { $0.kind == .podcasts })
    }

    func testCreateAddAndDedup() {
        let store = makeStore()
        let p = store.createPlaylist(name: "Road Trip")
        store.add(track("s1"), to: p.id)
        store.add(track("s1"), to: p.id)   // duplicate must be ignored
        store.add(track("s2"), to: p.id)
        XCTAssertEqual(store.playlists.first { $0.id == p.id }?.trackIDs, ["s1", "s2"])
    }

    func testRemoveByID() {
        let store = makeStore()
        let p = store.createPlaylist(name: "X")
        ["a", "b", "c"].forEach { store.add(track($0), to: p.id) }
        store.removeTrack(id: "b", from: p.id)
        XCTAssertEqual(store.playlists.first { $0.id == p.id }?.trackIDs, ["a", "c"])
    }

    func testMoveTracks() {
        let store = makeStore()
        let p = store.createPlaylist(name: "X")
        ["a", "b", "c"].forEach { store.add(track($0), to: p.id) }
        store.moveTracks(from: IndexSet(integer: 0), to: 3, in: p.id)  // move "a" to end
        XCTAssertEqual(store.playlists.first { $0.id == p.id }?.trackIDs, ["b", "c", "a"])
    }

    func testLikeToggle() {
        let store = makeStore()
        let t = track("liked1")
        XCTAssertFalse(store.isLiked(t))
        store.toggleLike(t)
        XCTAssertTrue(store.isLiked(t))
        store.toggleLike(t)
        XCTAssertFalse(store.isLiked(t))
    }

    func testPinCapAtTwenty() {
        let store = makeStore()
        let created = (0..<25).map { store.createPlaylist(name: "P\($0)") }
        for p in created {
            if let current = store.playlists.first(where: { $0.id == p.id }) {
                store.togglePin(current)
            }
        }
        // cap is 20; pinning 25 leaves exactly 20 pinned
        XCTAssertEqual(store.playlists.filter { $0.isPinned }.count, 20)
    }

    func testOrderedPlaylistsPinnedFirst() {
        let store = makeStore()
        let p = store.createPlaylist(name: "Pinned")
        if let current = store.playlists.first(where: { $0.id == p.id }) {
            store.togglePin(current)
        }
        XCTAssertEqual(store.orderedPlaylists.first?.id, p.id)
    }

    func testCannotDeleteSystemPlaylist() {
        let store = makeStore()
        if let liked = store.playlists.first(where: { $0.kind == .liked }) {
            store.delete(liked)
        }
        XCTAssertTrue(store.playlists.contains { $0.kind == .liked })
    }

    func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl-\(UUID().uuidString).json")
        let first = PlaylistStore(fileURL: url)
        let p = first.createPlaylist(name: "Persisted")
        first.add(track("z"), to: p.id)

        let second = PlaylistStore(fileURL: url)   // reload from same file
        XCTAssertTrue(second.playlists.contains { $0.name == "Persisted" && $0.trackIDs == ["z"] })
    }
}
