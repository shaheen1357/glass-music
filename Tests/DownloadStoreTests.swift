import XCTest
@testable import Music

/// Downloads live in their own folder, linked from the stream cache, so clearing or
/// trimming the cache (or iOS emptying it) never takes a download with it.
final class DownloadStoreTests: XCTestCase {

    private func names() -> (cache: URL, download: URL) {
        let name = "test-\(UUID().uuidString).flac"
        return (SubsonicCache.dir.appendingPathComponent(name),
                SubsonicCache.downloadsDir.appendingPathComponent(name))
    }

    func testLinkedDownloadIsFoundAtTheCachePathAndSurvivesClear() throws {
        let (cache, download) = names()
        try Data([1, 2, 3, 4]).write(to: download)
        SubsonicCache.link(cache)

        XCTAssertTrue(SubsonicCache.isDownloaded(cache))
        XCTAssertTrue(SubsonicCache.isCached(cache))          // the player's path finds it
        XCTAssertTrue(SubsonicCache.isLink(cache))

        SubsonicCache.clear()                                 // "Clear Play Cache"
        XCTAssertTrue(SubsonicCache.isCached(cache))
        XCTAssertTrue(SubsonicCache.isDownloaded(cache))

        SubsonicCache.removeDownload(cache)
        XCTAssertFalse(SubsonicCache.isCached(cache))
        XCTAssertFalse(SubsonicCache.isDownloaded(cache))
    }

    func testLinkReplacesAPlainCachedCopyAndRelinksAfterPurge() throws {
        let (cache, download) = names()
        try Data([9]).write(to: cache)                        // played earlier, cached
        try Data([1, 2, 3]).write(to: download)
        SubsonicCache.link(cache)
        XCTAssertEqual(try Data(contentsOf: cache), Data([1, 2, 3]))

        try FileManager.default.removeItem(at: cache)          // iOS empties Caches
        XCTAssertFalse(SubsonicCache.isCached(cache))
        SubsonicCache.link(cache)                             // startup relink
        XCTAssertTrue(SubsonicCache.isCached(cache))
        SubsonicCache.removeDownload(cache)
    }

    func testClearRemovesPlainCachedFiles() throws {
        let (cache, _) = names()
        try Data([7]).write(to: cache)
        SubsonicCache.clear()
        XCTAssertFalse(SubsonicCache.isCached(cache))
    }

    // iOS can move the app's container between launches; saved full paths go stale.
    func testCurrentURLReRootsAPathFromAnEarlierContainer() {
        let old = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD/Library/Caches/StreamCache/abc.flac")
        XCTAssertEqual(SubsonicCache.currentURL(for: old), SubsonicCache.dir.appendingPathComponent("abc.flac"))
    }

    // Subsonic answers a bad request with a 200 and a JSON/XML body; that must never
    // be saved as the song.
    func testErrorBodiesAreNotAudio() {
        let u = URL(string: "https://example.com/rest/download")!
        func r(_ mime: String) -> URLResponse {
            URLResponse(url: u, mimeType: mime, expectedContentLength: 10, textEncodingName: nil)
        }
        XCTAssertTrue(SubsonicCache.looksLikeAudio(r("audio/flac")))
        XCTAssertTrue(SubsonicCache.looksLikeAudio(r("application/octet-stream")))
        XCTAssertFalse(SubsonicCache.looksLikeAudio(r("application/json")))
        XCTAssertFalse(SubsonicCache.looksLikeAudio(r("text/xml")))
    }

    // Download Quality 320/192 saves "<id>.mp3"; the song still looks up as "<id>.flac".
    func testConvertedDownloadIsFoundUnderTheSongsCacheName() throws {
        let id = "test-\(UUID().uuidString)"
        let cache = SubsonicCache.dir.appendingPathComponent(id + ".flac")
        let mp3 = SubsonicCache.downloadsDir.appendingPathComponent(id + ".mp3")
        try Data([0xFF, 0xFB]).write(to: mp3)

        XCTAssertTrue(SubsonicCache.isDownloaded(cache))
        XCTAssertEqual(SubsonicCache.downloadedFile(for: cache).lastPathComponent, id + ".mp3")

        SubsonicCache.removeDownload(cache)
        XCTAssertFalse(SubsonicCache.isDownloaded(cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp3.path))
    }
}
