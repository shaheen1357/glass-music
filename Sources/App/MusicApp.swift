import SwiftUI

@main
struct MusicApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerEngine()
    @StateObject private var playlists = PlaylistStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(playlists)
                .tint(Color.accentColor)
                .task { await library.scan() }
        }
    }
}
