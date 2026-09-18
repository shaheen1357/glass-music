import SwiftUI

@main
struct MusicApp: App {
    // Owned by AppServices so App Intents (Siri/Shortcuts) drive the same instances.
    @State private var player = AppServices.shared.player
    @StateObject private var library = AppServices.shared.library
    @StateObject private var playlists = AppServices.shared.playlists
    @StateObject private var stats = AppServices.shared.stats
    @StateObject private var recents = AppServices.shared.recents
    @Environment(\.scenePhase) private var scenePhase

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
                    player.onNeedMore = { [weak library] last, existing in
                        library?.autoplaySuggestions(after: last, excluding: existing) ?? []
                    }
                    await library.scan()
                    // Restore the last session (paused) once the library is loaded
                    // so track IDs resolve to real files.
                    player.restorePlaybackState(using: library)
                }
                .onChange(of: scenePhase) { _, phase in
                    // Save when leaving the app so the position survives a later kill.
                    if phase == .background { player.persistNow() }
                }
                .onOpenURL { url in
                    // "Open in Music" from AirDrop / the share sheet / Files.
                    library.importFiles([url])
                }
        }
    }
}
