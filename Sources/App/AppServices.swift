import Foundation

/// App-wide singletons shared between the SwiftUI UI and App Intents (Siri /
/// Shortcuts), which run in-process but outside the view hierarchy. Both the app
/// and the intents use these exact instances, so a Siri command controls the same
/// player you see on screen.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let player = PlayerEngine()
    let library = LibraryStore()
    let playlists = PlaylistStore()
    let stats = PlayStatsStore()
    let recents = RecentSearchStore()

    private init() {}

    // MARK: - Intent actions
    func playPause() { player.togglePlayPause() }
    func next() { player.next() }
    func previous() { player.previous() }

    func shuffleLiked() async {
        await library.scan()                       // cache-instant if already scanned
        guard let liked = playlists.liked else { return }
        let tracks = playlists.tracks(for: liked, in: library)
        if !tracks.isEmpty { player.playShuffled(tracks) }
    }

    func shuffleAll() async {
        await library.scan()
        if !library.tracks.isEmpty { player.playShuffled(library.tracks) }
    }
}
