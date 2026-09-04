import SwiftUI

struct RootView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showNowPlaying = false
    @State private var selection = 0

    var body: some View {
        content
            .tint(Color.accentColor)
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(isPresented: $showNowPlaying)
                    .environmentObject(player)
                    .environmentObject(playlists)
            }
    }

    // Selection is held here so the current tab survives the mini player
    // appearing/disappearing (which otherwise rebuilds the TabView).
    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: 0) { HomeView() }
            Tab("Library", systemImage: "square.stack.fill", value: 1) { LibraryView() }
            Tab("Search", systemImage: "magnifyingglass", value: 2) { SearchView() }
        }
    }

    @ViewBuilder private var content: some View {
        let hasTrack = player.currentTrack != nil
        if #available(iOS 26.0, *) {
            // Only attach the accessory when something is playing, otherwise
            // iOS 26 shows an empty glass pill above the tab bar.
            if hasTrack {
                tabs.tabViewBottomAccessory {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                }
            } else {
                tabs
            }
        } else {
            tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                if hasTrack {
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
