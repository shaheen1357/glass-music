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
        let tabs = TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            LibraryView().tabItem { Label("Library", systemImage: "square.stack.fill") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
        if #available(iOS 26.0, *) {
            tabs.tabViewBottomAccessory {
                if player.currentTrack != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                }
            }
        } else {
            tabs.safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                }
            }
        }
    }
}
