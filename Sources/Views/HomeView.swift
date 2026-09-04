import SwiftUI

// Spotify-style content-first Home, Apple-Music aesthetic. No ads — your library.
struct HomeView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var stats: PlayStatsStore
    @State private var showSettings = false

    private let tile: CGFloat = 150

    private enum QuickItem: Identifiable {
        case playlist(Playlist)
        case album(Album)
        var id: String {
            switch self {
            case .playlist(let p): return "p-\(p.id)"
            case .album(let a): return "a-\(a.id)"
            }
        }
    }

    private var quickItems: [QuickItem] {
        // Quick-access grid is playlists only (albums/songs live in the shelves below).
        playlists.orderedPlaylists.prefix(6).map { .playlist($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.tracks.isEmpty {
                    if library.isScanning {
                        ProgressView("Scanning…").frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        EmptyLibraryHint().padding(.top, 40)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if !quickItems.isEmpty { quickGrid }

                        let recent = stats.recentlyPlayed(from: library.tracks, limit: 12)
                        let added = Array(library.albums.sorted { $0.dateAdded > $1.dateAdded }.prefix(12))
                        let most = stats.mostPlayed(from: library.tracks, limit: 12)

                        if !added.isEmpty { albumShelf("Recently Added", albums: added) }
                        if !recent.isEmpty { trackShelf("Recently Played", tracks: recent) }
                        if !most.isEmpty { trackShelf("On Repeat", tracks: most) }
                        if !playlists.playlists.isEmpty { playlistShelf("Your Playlists") }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environment(player).environmentObject(library)
            }
        }
    }

    // MARK: quick-access grid (the Spotify signature)
    private var quickGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(quickItems) { item in
                NavigationLink { quickDestination(item) } label: { quickTile(item) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func quickTile(_ item: QuickItem) -> some View {
        HStack(spacing: 0) {
            quickCover(item).frame(width: 56, height: 56)
            Text(quickName(item))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(height: 56)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private func quickCover(_ item: QuickItem) -> some View {
        switch item {
        case .playlist(let p):
            PlaylistCover(tracks: playlists.tracks(for: p, in: library), kind: p.kind,
                          corner: 0, coverData: p.coverImageData)
        case .album(let a):
            ArtworkView(id: a.id, data: a.artworkData, corner: 0)
        }
    }

    private func quickName(_ item: QuickItem) -> String {
        switch item {
        case .playlist(let p): return p.name
        case .album(let a): return a.title
        }
    }

    @ViewBuilder private func quickDestination(_ item: QuickItem) -> some View {
        switch item {
        case .playlist(let p): PlaylistDetailView(playlistID: p.id)
        case .album(let a): AlbumDetailView(album: a)
        }
    }

    // MARK: horizontal shelves
    private func header(_ title: String) -> some View {
        Text(title).font(.title2.bold()).padding(.horizontal)
    }

    private func trackShelf(_ title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button { player.play(tracks: tracks, startAt: index) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(id: track.id, data: track.artworkData, corner: 8).frame(width: tile, height: tile)
                                Text(track.title).font(.subheadline).lineLimit(1).frame(width: tile, alignment: .leading)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: tile, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func albumShelf(_ title: String, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(id: album.id, data: album.artworkData, corner: 8).frame(width: tile, height: tile)
                                Text(album.title).font(.subheadline).lineLimit(1).frame(width: tile, alignment: .leading)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: tile, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func playlistShelf(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(playlists.orderedPlaylists) { pl in
                        NavigationLink { PlaylistDetailView(playlistID: pl.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PlaylistCover(tracks: playlists.tracks(for: pl, in: library),
                                              kind: pl.kind, coverData: pl.coverImageData)
                                    .frame(width: tile, height: tile)
                                Text(pl.name).font(.subheadline).lineLimit(1).frame(width: tile, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
