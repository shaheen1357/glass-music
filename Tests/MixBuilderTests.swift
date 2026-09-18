import XCTest
@testable import Music

@MainActor
final class MixBuilderTests: XCTestCase {

    private func stats() -> PlayStatsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stats-\(UUID().uuidString).json")
        return PlayStatsStore(fileURL: url)
    }

    private func tracks(_ n: Int, artist: (Int) -> String = { _ in "A" }) -> [Track] {
        (0..<n).map { i in
            Track(id: "t\(i)", url: URL(fileURLWithPath: "/tmp/t\(i).flac"),
                  title: "T\(i)", artist: artist(i), album: "Alb", trackNumber: i,
                  duration: 100, artworkData: nil, dateAdded: Date().addingTimeInterval(Double(i)))
        }
    }

    func testTooSmallLibraryYieldsNoMixes() {
        XCTAssertTrue(MixBuilder.mixes(tracks: tracks(5), stats: stats(), liked: []).isEmpty)
    }

    func testDailyMixAlwaysPresentAndBounded() {
        let all = tracks(50)
        let mixes = MixBuilder.mixes(tracks: all, stats: stats(), liked: [])
        let daily = mixes.first { $0.id == "daily" }
        XCTAssertNotNil(daily)
        XCTAssertLessThanOrEqual(daily!.tracks.count, 30)
        XCTAssertFalse(daily!.tracks.isEmpty)
        // every track in the mix is from the library
        let ids = Set(all.map(\.id))
        XCTAssertTrue(daily!.tracks.allSatisfy { ids.contains($0.id) })
    }

    func testDailyMixIsDeterministicWithinADay() {
        let all = tracks(40)
        let s = stats()
        let a = MixBuilder.mixes(tracks: all, stats: s, liked: []).first { $0.id == "daily" }!
        let b = MixBuilder.mixes(tracks: all, stats: s, liked: []).first { $0.id == "daily" }!
        XCTAssertEqual(a.tracks.map(\.id), b.tracks.map(\.id))
    }

    func testFreshFindsAreUnplayed() {
        let all = tracks(20)
        let s = stats()
        // play the first 10 -> only the rest can be "fresh"
        all.prefix(10).forEach { s.recordPlay($0) }
        let fresh = MixBuilder.mixes(tracks: all, stats: s, liked: []).first { $0.id == "fresh" }
        XCTAssertNotNil(fresh)
        XCTAssertTrue(fresh!.tracks.allSatisfy { s.playCount($0.id) == 0 })
    }

    func testFavoritesMixSurfacesTopArtist() {
        // 8 by "Star", 8 by "Other"; play Star heavily
        let star = tracks(8) { _ in "Star" }
        let other = (0..<8).map { i in
            Track(id: "o\(i)", url: URL(fileURLWithPath: "/tmp/o\(i).flac"),
                  title: "O\(i)", artist: "Other", album: "Alb2", trackNumber: i,
                  duration: 100, artworkData: nil, dateAdded: Date())
        }
        let s = stats()
        star.forEach { s.recordPlay($0); s.recordPlay($0) }
        let faves = MixBuilder.mixes(tracks: star + other, stats: s, liked: []).first { $0.id == "faves" }
        XCTAssertNotNil(faves)
        XCTAssertTrue(faves!.tracks.contains { $0.artist == "Star" })
    }
}
