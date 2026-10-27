import SwiftUI

@main
struct MusicApp: App {
    // Owned by AppServices so App Intents (Siri/Shortcuts) drive the same instances.
    @State private var player = AppServices.shared.player
    @StateObject private var library = AppServices.shared.library
    @StateObject private var playlists = AppServices.shared.playlists
    @StateObject private var stats = AppServices.shared.stats
    @StateObject private var recents = AppServices.shared.recents
    @State private var sync = AppServices.shared.sync
    @State private var subsonic = AppServices.shared.subsonic
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environment(player)
                .environmentObject(playlists)
                .environmentObject(stats)
                .environmentObject(recents)
                .environment(sync)
                .environment(subsonic)
                .tint(Color.accentColor)
                .task {
                    player.onPlay = { track in stats.recordPlay(track); sync.scrobble(track) }
                    player.onNeedMore = { [weak library] last, existing in
                        library?.autoplaySuggestions(after: last, excluding: existing) ?? []
                    }
                    // Remote tracks resolve to a cached local file before the engine
                    // opens them; local tracks return instantly, unchanged.
                    player.ensureLocalURL = { track in await sync.ensureLocal(track) }
                    await library.scan()
                    // Restore the last session (paused) once the library is loaded
                    // so track IDs resolve to real files.
                    player.restorePlaybackState(using: library)
                    // Pull the server catalog + playlists in the background so local
                    // playback is instant and the server folds in when it's ready.
                    Task { await sync.syncNow() }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Save when leaving the app so the position survives a later kill,
                    // and push any playlist edits up to the server.
                    if phase == .background {
                        player.persistNow()
                        Task { await sync.pushPlaylists() }
                    }
                }
                .onOpenURL { url in
                    // "Open in Music" from AirDrop / the share sheet / Files.
                    library.importFiles([url])
                }
        }
    }
}
