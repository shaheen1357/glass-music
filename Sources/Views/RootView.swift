import SwiftUI

struct RootView: View {
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showNowPlaying = false
    @State private var selection = 0

    var body: some View {
        content
            .tint(Color.accentColor)
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(isPresented: $showNowPlaying)
                    .environment(player)
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
        if #available(iOS 26.1, *) {
            // Modifier is ALWAYS applied; only the Bool changes, so the TabView
            // keeps its structural identity — no rebuild. Playing the first song
            // no longer resets your tab / open playlist. isEnabled: is a shipping
            // (non-beta) iOS 26.1 API, and it hides the empty pill cleanly.
            tabs.tabViewBottomAccessory(isEnabled: hasTrack) {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
            }
        } else if #available(iOS 26.0, *) {
            // 26.0 lacks isEnabled, but the content-only modifier is still applied
            // unconditionally here (the check is INSIDE), so identity stays stable
            // and empty content hides cleanly on 26.0.
            tabs.tabViewBottomAccessory {
                if hasTrack {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
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
                }
            }
        }
    }
}
