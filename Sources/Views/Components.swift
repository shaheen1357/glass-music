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

// MARK: - Track row (Apple Music style) with Love / Add-to-Playlist menu
struct TrackRow: View {
    let track: Track
    var showArtwork: Bool = true
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var showAdd = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
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
        .contextMenu {
            Button { playlists.toggleLike(track) } label: {
                if playlists.isLiked(track) {
                    Label("Remove from Liked Songs", systemImage: "heart.slash")
                } else {
                    Label("Love", systemImage: "heart")
                }
            }
            Button { showAdd = true } label: {
                Label("Add to a Playlist…", systemImage: "text.badge.plus")
            }
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
