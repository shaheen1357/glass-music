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
}
