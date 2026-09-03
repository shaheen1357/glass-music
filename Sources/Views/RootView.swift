import SwiftUI

struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showNowPlaying = false

    var body: some View {
        content
            .tint(Color.accentColor)
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(isPresented: $showNowPlaying)
                    .environmentObject(player)
                    .environmentObject(playlists)
            }
    }

    @ViewBuilder private var content: some View {
        // One universal path: safeAreaInset keeps the system tab bar visible on
        // every iOS version (the iOS 26 tabViewBottomAccessory was hiding it).
        // The mini player sits as a frosted glass bar directly above the tabs.
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            LibraryView().tabItem { Label("Library", systemImage: "square.stack.fill") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    }
            }
        }
    }
}
