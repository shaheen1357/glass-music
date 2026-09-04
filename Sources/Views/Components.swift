import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// `.presentationBackground` is iOS 16.4+. Apply the material only when
    /// available so the iOS 16.0 deployment target still compiles and runs.
    @ViewBuilder func materialSheetBackground() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(.ultraThinMaterial)
        } else {
            self
        }
    }
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

// MARK: - Sleep timer (shared by Settings + full player)
/// Live countdown while a timed sleep is running; otherwise the mode text.
struct SleepStatusText: View {
    @EnvironmentObject private var player: PlayerEngine
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
    @EnvironmentObject private var player: PlayerEngine
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
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore

    var body: some View {
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
        Button { playlists.toggleLike(track) } label: {
            Label(playlists.isLiked(track) ? "Remove from Liked Songs" : "Love",
                  systemImage: playlists.isLiked(track) ? "heart.slash" : "heart")
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
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showAdd = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 8) {
            Button { onPlay?() } label: {
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
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
