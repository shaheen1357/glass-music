import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Haptics (light physical feedback on transport + toggles)
// UIFeedbackGenerator is @MainActor-isolated; every caller is already on the main
// actor (Button actions, gesture callbacks), so isolate the whole helper.
@MainActor
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// MARK: - Sort options (Apple Music vocabulary)
enum ItemSort: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case title = "Title"
    case artist = "Artist"
    var id: String { rawValue }
}

enum PlaylistSort: String, CaseIterable, Identifiable {
    case custom = "Playlist Order"
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case recentlyAdded = "Recently Added"
    var id: String { rawValue }
}

// MARK: - Time formatting
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

func totalTimeString(_ seconds: Double) -> String {
    let minutes = max(0, Int(seconds / 60))
    if minutes < 60 { return "\(minutes) min" }
    let h = minutes / 60, m = minutes % 60
    return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
}

func songCountString(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }

// MARK: - Artwork
/// Process-wide cache of decoded artwork, keyed by a stable id (track/album id).
enum ArtworkCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024   // ~64 MB of decoded bitmaps, not a raw count
        return c
    }()
}

struct ArtworkView: View {
    let id: String
    let data: Data?
    var corner: CGFloat = 8
    @State private var decoded: UIImage?

    // Synchronous read: a cache hit returns instantly, so re-renders (incl. the
    // 5Hz playback ticks) never flash to the placeholder. Falls back to the
    // last off-main decode, else nil -> placeholder.
    private var displayImage: UIImage? {
        ArtworkCache.shared.object(forKey: id as NSString) ?? decoded
    }

    var body: some View {
        Group {
            if let ui = displayImage {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .task(id: id) {
            // Only work on a cache miss; decode off the main thread so scrolling
            // in new cells doesn't hitch, then cache for instant reuse.
            // On a cache hit, keep our own strong copy in @State. The mini player
            // is long-lived and never re-runs this task (id doesn't change), so if
            // we relied only on the shared NSCache — which iOS purges on memory
            // pressure while backgrounded — the artwork would blank out on return.
            if let cached = ArtworkCache.shared.object(forKey: id as NSString) {
                decoded = cached
                return
            }
            guard let data else { return }
            // UIImage(data:) is LAZY — it defers the pixel decode to the main
            // thread at draw time, which is the real scroll-jank source.
            // preparingForDisplay() forces the full decode HERE, off the main
            // thread, so drawing the cell is just a cheap blit.
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let raw = UIImage(data: data) else { return nil }
                return raw.preparingForDisplay() ?? raw
            }.value
            guard let img else { return }
            let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            ArtworkCache.shared.setObject(img, forKey: id as NSString, cost: cost)
            decoded = img
        }
    }
}

// MARK: - Share sheet (present a file/URL via the system activity sheet)
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Sleep timer (shared by Settings + full player)
/// Live countdown while a timed sleep is running; otherwise the mode text.
struct SleepStatusText: View {
    @Environment(PlayerEngine.self) private var player
    var body: some View {
        let now = Date()
        if let end = player.sleepEndDate, end > now {
            Text(timerInterval: now...end, countsDown: true)
        } else if player.sleepAtTrackEnd {
            Text("End of Track")
        } else {
            Text("Off")
        }
    }
}

/// The sleep-timer menu with a checkmark on the active choice, so you can always
/// see what's set. Caller supplies its own label to match its surroundings.
struct SleepTimerMenu<MenuLabel: View>: View {   // not `Label` — that shadows SwiftUI.Label
    @Environment(PlayerEngine.self) private var player
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            Button { player.cancelSleepTimer() } label: {
                item("Off", active: player.sleepTimerMinutes == nil && !player.sleepAtTrackEnd)
            }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in
                Button { player.startSleepTimer(minutes: m) } label: {
                    item("\(m) minutes", active: player.sleepTimerMinutes == m)
                }
            }
            Button { player.sleepAtEndOfTrack() } label: {
                item("End of Track", active: player.sleepAtTrackEnd)
            }
        } label: { label() }
    }

    @ViewBuilder private func item(_ title: String, active: Bool) -> some View {
        if active { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

// MARK: - Shared track actions (used by the ⋯ menu and long-press)
struct TrackActions: View {
    let track: Track
    var onPlay: (() -> Void)? = nil
    var onAddToPlaylist: () -> Void
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(SubsonicSync.self) private var sync: SubsonicSync?

    var body: some View {
        // Where this song plays from and at what quality ("Downloaded · FLAC",
        // "Streams as MP3 320"), as a quiet line at the top of its menu.
        if let sync, let quality = sync.qualityDescription(track) {
            Text(quality)
            Divider()
        }
        if let onPlay {
            Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        }
        Button { player.playNext(track) } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button { player.addToQueue(track) } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button { onAddToPlaylist() } label: {
            Label("Add to a Playlist…", systemImage: "text.badge.plus")
        }
        Button {
            playlists.toggleLike(track)
            sync?.setLiked(track, liked: playlists.isLiked(track))
        } label: {
            Label(playlists.isLiked(track) ? "Remove from Liked Songs" : "Love",
                  systemImage: playlists.isLiked(track) ? "heart.slash" : "heart")
        }
        if let sync, SubsonicID.isRemote(track) {
            if sync.isManuallyDownloaded(track) {
                Button { sync.removeDownload(track) } label: {
                    Label("Remove Download", systemImage: "arrow.down.circle.fill")
                }
            } else if sync.isHeldByCollection(track) {
                // Kept by a downloaded playlist or album: removed from there, not here.
                Button {} label: {
                    Label("Downloaded with a Playlist or Album", systemImage: "arrow.down.circle.fill")
                }
                .disabled(true)
            } else {
                Button { sync.download(track) } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
        Menu {
            Button("Off") { player.cancelSleepTimer() }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in
                Button("\(m) minutes") { player.startSleepTimer(minutes: m) }
            }
            Button("End of Track") { player.sleepAtEndOfTrack() }
        } label: {
            Label("Sleep Timer", systemImage: "moon.zzz")
        }
    }
}

// MARK: - ⋯ menu button reused across rows
struct TrackMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Track row (Apple Music style): tap to play + trailing ⋯ menu
struct TrackRow: View {
    let track: Track
    var showArtwork: Bool = true
    var onPlay: (() -> Void)? = nil
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(SubsonicSync.self) private var sync: SubsonicSync?
    @State private var showAdd = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }
    private var isPending: Bool { track.isPending }

    var body: some View {
        HStack(spacing: 8) {
            Button { if !isPending { onPlay?() } } label: {
                HStack(spacing: 12) {
                    if showArtwork {
                        ArtworkView(id: track.id, data: track.artworkData, corner: 6).frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(1)
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if playlists.isLiked(track) {
                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.accentColor)
                    }
                    if isPending {
                        // On the phone's playlist but not on the server yet — upload it.
                        Image(systemName: "arrow.up.circle").font(.caption2).foregroundStyle(.secondary)
                    }
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                }
                .contentShape(Rectangle())
                .opacity(isPending ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isPending)

            offlineBadge                        // its own switch: tapping it never plays

            Menu {
                TrackActions(track: track, onPlay: onPlay, onAddToPlaylist: { showAdd = true })
            } label: {
                TrackMenuLabel()
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showAdd) {
            AddToPlaylistView(track: track).environmentObject(playlists)
        }
    }

    // On-device state for a server track: filled arrow = downloaded for offline,
    private var offlineBadge: some View { OfflineBadge(track: track) }
}

// MARK: - Download state (Spotify-style)
/// Where a song is, beside its title in every list, and the switch for it. A song
/// that is your own file on the phone shows nothing. From the server:
///   cloud        streams          tap: download it
///   green ring   downloading      tap: stop
///   clock        waiting for Wi-Fi  tap: go now on mobile data, or stop
///   red mark     failed           tap: retry
///   green disc   downloaded       tap: remove the download
/// A song kept by a downloaded playlist or album says so instead of removing: it
/// comes off by removing that playlist's or album's download.
struct OfflineBadge: View {
    let track: Track
    @Environment(SubsonicSync.self) private var sync: SubsonicSync?
    @State private var ask: Ask?

    private enum Ask: Identifiable { case held, waiting; var id: Self { self } }

    var body: some View {
        if let sync, SubsonicID.isRemote(track) {
            let state = sync.availability(track)
            if state != .cached && state != .local {
                Button { tap(state, sync) } label: { glyph(state, sync) }
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .confirmationDialog(dialogTitle, isPresented: Binding(
                        get: { ask != nil }, set: { if !$0 { ask = nil } }), titleVisibility: .visible) {
                        if ask == .waiting {
                            Button("Download Now on Mobile Data") { sync.downloadWaitingOnMobileData() }
                            if sync.isManuallyDownloaded(track) {
                                Button("Stop Download", role: .destructive) { sync.removeDownload(track) }
                            }
                        }
                        Button("OK", role: .cancel) {}
                    } message: {
                        if ask == .held {
                            Text("It's downloaded with a playlist or album. Remove that playlist's or album's download, or take the song out of it.")
                        }
                    }
            }
        }
    }

    private var dialogTitle: String { ask == .waiting ? "Waiting for Wi-Fi" : "Kept by a download" }

    private func tap(_ state: SubsonicSync.Availability, _ sync: SubsonicSync) {
        let manual = sync.isManuallyDownloaded(track)
        switch state {
        case .streams: sync.download(track)
        case .failed: sync.retryFailed()
        case .waiting: ask = .waiting
        case .downloading, .downloaded:
            if manual { sync.removeDownload(track) } else { ask = .held }
        case .cached, .local: break
        }
    }

    @ViewBuilder private func glyph(_ state: SubsonicSync.Availability, _ sync: SubsonicSync) -> some View {
        switch state {
        case .downloaded:
            DownloadedBadge(size: 14).accessibilityHint("Removes the download")
        case .downloading:
            DownloadRing(progress: sync.downloadProgress(track) ?? 0, size: 14, lineWidth: 1.8)
                .accessibilityHint("Stops the download")
        case .waiting:
            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Waiting for Wi-Fi")
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Download failed").accessibilityHint("Retries")
        case .streams:
            Image(systemName: "cloud").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Streams from the server").accessibilityHint("Downloads it")
        case .cached, .local:
            EmptyView()
        }
    }
}

/// The download switch for a playlist or album, in the same spot whatever its state:
/// plain arrow (tap: download), a ring filling green (tap: stop), a solid green disc
/// once it's all on the phone (tap: remove the download). Hidden when there's nothing
/// to download or remove: every song is your own file, or downloaded one by one.
/// On mobile data it asks first; while songs wait for Wi-Fi it says so.
struct CollectionDownloadButton: View {
    let ruleKey: String
    let tracks: [Track]
    @Environment(SubsonicSync.self) private var sync: SubsonicSync?
    @State private var ask: Ask?

    private enum Ask: Identifiable { case cellular, stop, remove; var id: Self { self } }

    var body: some View {
        if let sync {
            let status = sync.status(of: tracks)
            let on = sync.isDownloadRule(ruleKey)
            if status.total > 0 && (on || !status.complete) {
                HStack(spacing: 8) {
                    Button {
                        if on { ask = status.complete ? .remove : .stop }
                        else if sync.isOnCellular && !sync.downloadOnMobileData { ask = .cellular }
                        else { sync.setDownloadRule(ruleKey, on: true) }
                    } label: {
                        if on && status.complete {
                            DownloadedBadge(size: 26)
                        } else if on {
                            DownloadRing(progress: status.fraction, size: 26, lineWidth: 3)
                        } else {
                            Image(systemName: "arrow.down.circle").font(.system(size: 26)).foregroundStyle(.primary)
                                .accessibilityLabel("Download")
                        }
                    }
                    .buttonStyle(.plain)
                    if on && status.waiting > 0 {
                        Button("Waiting for Wi-Fi") { ask = .cellular }
                            .font(.caption).foregroundStyle(.secondary)
                    } else if on && status.failed > 0 {
                        Button("\(status.failed) failed · Retry") { sync.retryFailed() }
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .confirmationDialog(title(for: ask), isPresented: Binding(
                    get: { ask != nil }, set: { if !$0 { ask = nil } }), titleVisibility: .visible) {
                    switch ask {
                    case .cellular:
                        Button("Download Now") {
                            if on { sync.downloadWaitingOnMobileData() }
                            else { sync.setDownloadRule(ruleKey, on: true, allowCellular: true) }
                        }
                        if !on { Button("Wait for Wi-Fi") { sync.setDownloadRule(ruleKey, on: true) } }
                    case .stop:
                        Button("Stop Downloading", role: .destructive) { sync.setDownloadRule(ruleKey, on: false) }
                    case .remove:
                        Button("Remove Download", role: .destructive) { sync.setDownloadRule(ruleKey, on: false) }
                    case nil:
                        EmptyView()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    switch ask {
                    case .cellular: Text("These are full-quality files, about 25 MB a song.")
                    case .remove, .stop: Text("The songs stay in the playlist and stream from the server.")
                    case nil: EmptyView()
                    }
                }
            }
        }
    }

    private func title(for ask: Ask?) -> String {
        switch ask {
        case .cellular: return "You're on mobile data"
        case .stop: return "Stop downloading?"
        case .remove: return "Remove download?"
        case nil: return ""
        }
    }
}

/// A ring that fills green as a song — or a whole playlist — comes down.
struct DownloadRing: View {
    var progress: Double            // 0...1
    var size: CGFloat = 22
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))   // a sliver shows it has started
                .stroke(Color.green, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int((min(1, progress) * 100).rounded())) percent")
    }
}

/// Everything is on the phone: a solid green disc with the arrow.
struct DownloadedBadge: View {
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.green)
            .font(.system(size: size))
            .accessibilityLabel("Downloaded")
    }
}

// MARK: - Import button (document picker)
struct ImportButton: View {
    @EnvironmentObject var library: LibraryStore
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: { Image(systemName: "plus") }
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
    }
}

// MARK: - Recently added grid (Apple Music)
struct RecentlyAddedGrid: View {
    let albums: [Album]
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(albums) { album in
                NavigationLink { AlbumDetailView(album: album) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(id: album.id, data: album.artworkData, corner: 8).aspectRatio(1, contentMode: .fit)
                        Text(album.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                        Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
