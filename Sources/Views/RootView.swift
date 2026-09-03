import SwiftUI

struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        .tint(Color.accentColor)
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .padding(.bottom, 2)
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(isPresented: $showNowPlaying)
                .environmentObject(player)
                .environmentObject(playlists)
        }
    }
}
