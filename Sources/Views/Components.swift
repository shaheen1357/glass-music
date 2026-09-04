import SwiftUI
import UniformTypeIdentifiers

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
struct ArtworkView: View {
    let data: Data?
    var corner: CGFloat = 8

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
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
    }
}

// MARK: - Shared track actions (used by the ⋯ menu and long-press)
struct TrackActions: View {
    let track: Track
    var onPlay: (() -> Void)? = nil
    var onAddToPlaylist: () -> Void
    @EnvironmentObject var player: PlayerEngine
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
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showAdd = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 8) {
            Button { onPlay?() } label: {
                HStack(spacing: 12) {
                    if showArtwork {
                        ArtworkView(data: track.artworkData, corner: 6).frame(width: 48, height: 48)
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
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
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
                        ArtworkView(data: album.artworkData, corner: 8).aspectRatio(1, contentMode: .fit)
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
