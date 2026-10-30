import XCTest
@testable import Music

/// Local file -> server twin matching. Cases are the real misses from the
/// 2026-10-30 playlist push, where 85 entries were silently dropped.
final class RemoteIndexTests: XCTestCase {

    private func local(_ file: String, title: String, artist: String, album: String,
                       duration: Double) -> Track {
        Track(id: file, url: URL(fileURLWithPath: "/docs/\(file)"),
              title: title, artist: artist, album: album, trackNumber: 0,
              duration: duration, artworkData: nil, dateAdded: Date())
    }

    // Navidrome sends int32(duration) and joins multiple artists with " • ".
    private func remote(_ id: String, path: String?, title: String, artist: String,
                        album: String, duration: Double) -> Track {
        Track(id: SubsonicID.prefix + id, url: URL(fileURLWithPath: "/cache/\(id).flac"),
              title: title, artist: artist, album: album, trackNumber: 1,
              duration: Double(Int(duration)), artworkData: nil, dateAdded: Date(),
              sourcePath: path)
    }

    func testLooseKeyTruncatesLikeNavidrome() {
        // 466.89s locally, 466 from the server: rounding made these 467 vs 466.
        let l = local("Tame Impala - Let It Happen.flac", title: "Let It Happen",
                      artist: "Tame Impala", album: "Currents", duration: 466.89)
        let r = remote("a", path: nil, title: "Let It Happen",
                       artist: "Tame Impala • Kevin Parker", album: "Currents", duration: 466.89)
        XCTAssertEqual(l.looseKey, r.looseKey)
        XCTAssertEqual(RemoteIndex([r]).twin(of: l)?.id, r.id)
    }

    func testMultiArtistTagStillMatches() {
        let l = local("Rompasso - Angetenar.flac", title: "Angetenar",
                      artist: "Rompasso", album: "Angetenar", duration: 190.91)
        let r = remote("b", path: nil, title: "Angetenar",
                       artist: "Rompasso • Rich The Kid", album: "Angetenar", duration: 190.91)
        XCTAssertNotEqual(l.contentKey, r.contentKey)
        XCTAssertEqual(RemoteIndex([r]).twin(of: l)?.id, r.id)
    }

    func testFileNameWinsOverSameTitleAndLength() {
        // Two server files of one song: matching by title+length sent both phone
        // entries to the first file, doubling it in the playlist.
        let r1 = remote("f1", path: "/music/original volume 8/Fat Papi - FREAKED OUT.flac",
                        title: "FREAKED OUT", artist: "Fat Papi", album: "X", duration: 158.12)
        let r2 = remote("f2", path: "/music/original volume 8/Fat Papi - FREAKED OUT 2.flac",
                        title: "FREAKED OUT", artist: "Fat Papi", album: "X", duration: 158.12)
        let l2 = local("Fat Papi - FREAKED OUT 2.flac", title: "FREAKED OUT",
                       artist: "Fat Papi", album: "X", duration: 158.12)
        XCTAssertEqual(RemoteIndex([r1, r2]).twin(of: l2)?.id, r2.id)
    }

    func testFakeRelativePathIsIgnored() {
        let r = remote("c", path: "Fat Papi/X/01 - FREAKED OUT.flac",
                       title: "FREAKED OUT", artist: "Fat Papi", album: "X", duration: 158.12)
        XCTAssertNil(r.fileNameKey)
    }

    func testFileNameIgnoresUnicodeNormalisationAndCase() {
        let decomposed = "Yaego - recue\u{301}rdame (eterno).flac"
        let l = local(decomposed, title: "a", artist: "a", album: "a", duration: 1)
        let r = remote("d", path: "/music/dream/YAEGO - recuérdame (eterno).flac",
                       title: "b", artist: "b", album: "b", duration: 2)
        XCTAssertEqual(RemoteIndex([r]).twin(of: l)?.id, r.id)
    }

    func testNoTwinForPhoneOnlySong() {
        let r = remote("e", path: "/music/x/Other.flac", title: "Other",
                       artist: "Z", album: "Z", duration: 100)
        let l = local("BIA - WE ON GO 2.flac", title: "WE ON GO 2",
                      artist: "BIA", album: "Y", duration: 150)
        let index = RemoteIndex([r])
        XCTAssertNil(index.twin(of: l))
        XCTAssertFalse(index.hasTitle(l.title))
        XCTAssertTrue(index.hasTitle("other"))
    }
}
