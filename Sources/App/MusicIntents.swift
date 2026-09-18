import AppIntents

// Siri / Shortcuts control. These run in-process and drive the SAME player as the
// UI via AppServices.shared. App Intents need no extension target and no App Group,
// so they work under a free-account sideloaded build (unlike widgets/CarPlay).

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult {
        AppServices.shared.playPause()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult {
        AppServices.shared.next()
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var openAppWhenRun: Bool = false
    @MainActor func perform() async throws -> some IntentResult {
        AppServices.shared.previous()
        return .result()
    }
}

struct ShuffleLikedIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Liked Songs"
    static var openAppWhenRun: Bool = true      // start fresh playback, so open the app
    @MainActor func perform() async throws -> some IntentResult {
        await AppServices.shared.shuffleLiked()
        return .result()
    }
}

struct ShuffleAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle All Songs"
    static var openAppWhenRun: Bool = true
    @MainActor func perform() async throws -> some IntentResult {
        await AppServices.shared.shuffleAll()
        return .result()
    }
}

struct MusicAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(),
                    phrases: ["Play or pause \(.applicationName)", "Pause \(.applicationName)"],
                    shortTitle: "Play or Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(),
                    phrases: ["Next track in \(.applicationName)", "Skip in \(.applicationName)"],
                    shortTitle: "Next", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousTrackIntent(),
                    phrases: ["Previous track in \(.applicationName)"],
                    shortTitle: "Previous", systemImageName: "backward.fill")
        AppShortcut(intent: ShuffleLikedIntent(),
                    phrases: ["Shuffle my Liked Songs in \(.applicationName)", "Shuffle Liked in \(.applicationName)"],
                    shortTitle: "Shuffle Liked", systemImageName: "heart.fill")
        AppShortcut(intent: ShuffleAllIntent(),
                    phrases: ["Shuffle all songs in \(.applicationName)", "Shuffle everything in \(.applicationName)"],
                    shortTitle: "Shuffle All", systemImageName: "shuffle")
    }
}
