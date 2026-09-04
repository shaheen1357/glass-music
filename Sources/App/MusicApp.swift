import SwiftUI

@main
struct MusicApp: App {
    @StateObject private var library = LibraryStore()
    @State private var player = PlayerEngine()
    @StateObject private var playlists = PlaylistStore()
    @StateObject private var stats = PlayStatsStore()
    @StateObject private var recents = RecentSearchStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environment(player)
                .environmentObject(playlists)
                .environmentObject(stats)
                .environmentObject(recents)
                .tint(Color.accentColor)
                .task {
                    player.onPlay = { track in stats.recordPlay(track) }
                    await library.scan()
                }
        }
    }
}
