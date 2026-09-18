import XCTest
@testable import Music

@MainActor
final class PlayStatsStoreTests: XCTestCase {

    private func makeStore() -> PlayStatsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString).json")
        return PlayStatsStore(fileURL: url)
    }

    private func track(_ id: String) -> Track {
        Track(id: id, url: URL(fileURLWithPath: "/tmp/\(id).flac"),
              title: id, artist: "A", album: "B", trackNumber: 0,
              duration: 100, artworkData: nil, dateAdded: Date())
    }

    private func playlist(_ id: String) -> Playlist {
        Playlist(id: id, name: id, kind: .user, trackIDs: [])
    }

    // MARK: - Track stats
    func testRecordPlayCountsAndRecency() {
        let s = makeStore()
        s.recordPlay(track("a"))
        s.recordPlay(track("b"))
        s.recordPlay(track("a"))
        XCTAssertEqual(s.playCount("a"), 2)
        XCTAssertEqual(s.playCount("b"), 1)
        XCTAssertEqual(s.playCount("z"), 0)
        // most-recent first, deduplicated
        XCTAssertEqual(s.recentlyPlayedIDs.first, "a")
        XCTAssertEqual(s.recentlyPlayedIDs, ["a", "b"])
        XCTAssertEqual(s.resumeTrackID, "a")
    }

    func testMostPlayedOrdering() {
        let s = makeStore()
        (0..<3).forEach { _ in s.recordPlay(track("hot")) }
        s.recordPlay(track("cold"))
        let tracks = [track("cold"), track("hot"), track("never")]
        let most = s.mostPlayed(from: tracks, limit: 10)
        XCTAssertEqual(most.map(\.id), ["hot", "cold"])   // "never" has 0 plays -> excluded
    }

    // MARK: - Playlist interactions
    func testPlaylistInteractionCount() {
        let s = makeStore()
        s.recordPlaylistInteraction("p1")
        s.recordPlaylistInteraction("p1")
        s.recordPlaylistInteraction("p2")
        XCTAssertEqual(s.playlistInteractions("p1"), 2)
        XCTAssertEqual(s.playlistInteractions("p2"), 1)
        XCTAssertEqual(s.playlistInteractions("p3"), 0)
        XCTAssertNotNil(s.playlistLastPlayedDate("p1"))
        XCTAssertNil(s.playlistLastPlayedDate("p3"))
    }

    func testByInteractionsOrdersByCountThenStable() {
        let s = makeStore()
        s.recordPlaylistInteraction("b")   // 1
        s.recordPlaylistInteraction("c")   // c gets 2
        s.recordPlaylistInteraction("c")
        // input order a, b, c ; counts a=0, b=1, c=2
        let ordered = s.byInteractions([playlist("a"), playlist("b"), playlist("c")])
        XCTAssertEqual(ordered.map(\.id), ["c", "b", "a"])
    }

    func testByInteractionsStableForEqualCounts() {
        let s = makeStore()
        // nothing played -> all equal (0), must keep the input order
        let input = [playlist("x"), playlist("y"), playlist("z")]
        XCTAssertEqual(s.byInteractions(input).map(\.id), ["x", "y", "z"])
    }

    func testByLastPlayedPutsPlayedBeforeNeverPlayed() {
        let s = makeStore()
        s.recordPlaylistInteraction("mid")
        // input a(never), mid(played), z(never)
        let ordered = s.byLastPlayed([playlist("a"), playlist("mid"), playlist("z")])
        XCTAssertEqual(ordered.first?.id, "mid")                 // played leads
        XCTAssertEqual(Array(ordered.dropFirst()).map(\.id), ["a", "z"])  // never-played keep input order
    }

    // MARK: - Persistence
    func testPersistenceRoundTripIncludesPlaylistStats() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString).json")
        let first = PlayStatsStore(fileURL: url)
        first.recordPlay(track("t"))
        first.recordPlaylistInteraction("pl")

        let second = PlayStatsStore(fileURL: url)   // reload from same file
        XCTAssertEqual(second.playCount("t"), 1)
        XCTAssertEqual(second.playlistInteractions("pl"), 1)
    }

    /// An older playstats.json written before the playlist fields existed must still
    /// load (and keep the track stats) rather than throwing and wiping everything.
    func testDecodesLegacyFileWithoutPlaylistFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString).json")
        let legacy = """
        {"playCounts":{"t1":3},"recentlyPlayedIDs":["t1"],"lastPlayed":{},"resumeTrackID":"t1"}
        """
        try legacy.data(using: .utf8)!.write(to: url)

        let s = PlayStatsStore(fileURL: url)
        XCTAssertEqual(s.playCount("t1"), 3)                 // legacy stats preserved
        XCTAssertEqual(s.playlistInteractions("anything"), 0) // new fields default empty
    }
}
