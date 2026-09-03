import SwiftUI

// Spotify-style content-first Home, Apple-Music aesthetic. No ads — your library.
struct HomeView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var stats: PlayStatsStore

    private let tile: CGFloat = 150

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let recent = stats.recentlyPlayed(from: library.tracks, limit: 12)
                    let added = Array(library.albums.sorted { $0.dateAdded > $1.dateAdded }.prefix(12))
                    let most = stats.mostPlayed(from: library.tracks, limit: 12)

                    if !recent.isEmpty { trackShelf("Recently Played", tracks: recent) }
                    if !added.isEmpty { albumShelf("Recently Added", albums: added) }
                    if !most.isEmpty { trackShelf("On Repeat", tracks: most) }
                    if !playlists.playlists.isEmpty { playlistShelf("Your Playlists") }

                    if library.tracks.isEmpty && !library.isScanning {
                        EmptyLibraryHint()
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Home")
        }
    }

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
                                ArtworkView(data: track.artworkData, corner: 8)
                                    .frame(width: tile, height: tile)
                                Text(track.title).font(.subheadline).lineLimit(1)
                                    .frame(width: tile, alignment: .leading)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: tile, alignment: .leading)
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
                                ArtworkView(data: album.artworkData, corner: 8)
                                    .frame(width: tile, height: tile)
                                Text(album.title).font(.subheadline).lineLimit(1)
                                    .frame(width: tile, alignment: .leading)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: tile, alignment: .leading)
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
                                Text(pl.name).font(.subheadline).lineLimit(1)
                                    .frame(width: tile, alignment: .leading)
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
