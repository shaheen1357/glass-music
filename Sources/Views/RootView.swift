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
        if #available(iOS 26.0, *) {
            // iOS 26: the value-based Tab API renders the floating Liquid Glass
            // tab bar, and tabViewBottomAccessory docks the mini player above it
            // (the exact pattern Apple Music uses). The previous build broke the
            // tab bar because it paired tabViewBottomAccessory with the legacy
            // .tabItem API — that mismatch hides the bar. The Tab API fixes it,
            // and the system supplies Liquid Glass to the accessory for free.
            TabView {
                Tab("Home", systemImage: "house.fill") { HomeView() }
                Tab("Library", systemImage: "square.stack.fill") { LibraryView() }
                Tab("Search", systemImage: "magnifyingglass") { SearchView() }
            }
            .tabViewBottomAccessory {
                if player.currentTrack != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                }
            }
        } else {
            TabView {
                Tab("Home", systemImage: "house.fill") { HomeView() }
                Tab("Library", systemImage: "square.stack.fill") { LibraryView() }
                Tab("Search", systemImage: "magnifyingglass") { SearchView() }
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
}
