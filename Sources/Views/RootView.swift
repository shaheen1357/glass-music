import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine
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

    // Classic value-based TabView (iOS 16). Selection is held here so the current
    // tab survives the mini player appearing/disappearing.
    private var tabs: some View {
        TabView(selection: $selection) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            LibraryView().tabItem { Label("Library", systemImage: "square.stack.fill") }.tag(1)
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(2)
        }
    }

    private var content: some View {
        // Float the mini player ABOVE the tab bar. On iOS 16 a bottom
        // safeAreaInset on a TabView sits in the same region as the tab bar and
        // hides it; an overlay padded up by the tab-bar height keeps both visible.
        // iPhone 8 has a home button → standard 49pt tab bar, no bottom inset.
        ZStack(alignment: .bottom) {
            tabs
            if player.currentTrack != nil {
                MiniPlayerView(showNowPlaying: $showNowPlaying, clock: player.clock)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                    }
                    .padding(.bottom, 49)
            }
        }
    }
}
