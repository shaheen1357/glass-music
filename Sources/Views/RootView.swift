import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var library: LibraryStore
    @State private var showNowPlaying = false
    @State private var selection = 0
    @Namespace private var playerNS

    var body: some View {
        content
            .tint(Color.accentColor)
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(isPresented: $showNowPlaying)
                    .environment(player)
                    .environmentObject(playlists)
                    .environmentObject(library)
                    // Apple-Music zoom out of the mini player (plain @State binding
                    // keeps the transition from falling back).
                    .navigationTransition(.zoom(sourceID: "player", in: playerNS))
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
        if #available(iOS 26.1, *) {
            // Always-applied modifier (only the Bool changes) keeps TabView
            // identity so the first song doesn't reset your tab. iOS 26.1 API.
            tabs.tabViewBottomAccessory(isEnabled: hasTrack) {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .matchedTransitionSource(id: "player", in: playerNS)
            }
        } else if #available(iOS 26.0, *) {
            tabs.tabViewBottomAccessory {
                if hasTrack {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .matchedTransitionSource(id: "player", in: playerNS)
                }
            }
        } else {
            tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                if hasTrack {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .background(.ultraThinMaterial)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                        }
                        .matchedTransitionSource(id: "player", in: playerNS)
                }
            }
        }
    }
}
