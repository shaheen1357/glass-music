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
                    // Pull the server catalog + playlists quietly in the background so
                    // local playback is instant and the server folds in when ready.
                    Task { await sync.autoSyncIfAllowed() }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Save when leaving so the position survives a later kill, and push
                    // playlist edits up; sync quietly again when brought to foreground.
                    if phase == .background {
                        player.persistNow()
                        // Mirror playlist edits up — but only if they actually changed,
                        // and never a catalog walk. Cheap, so backgrounding stays instant.
                        sync.pushIfChanged()
                    } else if phase == .active {
                        Task { await sync.autoSyncIfAllowed() }
                    }
                }
                .onOpenURL { url in
                    // "Open in Music" from AirDrop / the share sheet / Files.
                    library.importFiles([url])
                }
        }
    }
}
