import SwiftUI

struct ArtistDetailView: View {
    let artist: ArtistGroup
    @EnvironmentObject private var player: PlayerEngine

    private var albums: [Album] {
        let byAlbum = Dictionary(grouping: artist.tracks) { $0.album }
        return byAlbum.map { title, tracks in
            Album(id: "\(title)\u{1}\(artist.name)", title: title, artist: artist.name,
                  tracks: tracks.sorted {
                      if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                  })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var albumCountText: String {
        albums.count == 1 ? "1 album" : "\(albums.count) albums"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color(.systemGray5)).frame(width: 120, height: 120)
                        Image(systemName: "music.mic").font(.system(size: 44)).foregroundStyle(.secondary)
                    }
                    Text(artist.name).font(.title2.bold()).multilineTextAlignment(.center)
                    Text("\(songCountString(artist.tracks.count)) · \(albumCountText)")
                        .font(.caption).foregroundStyle(.secondary)
                    PlayShuffleButtons(tracks: artist.tracks)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if albums.count > 1 {
                Section("Albums") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { album in
                                NavigationLink { AlbumDetailView(album: album) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ArtworkView(id: album.id, data: album.artworkData, corner: 8)
                                            .frame(width: 130, height: 130)
                                        Text(album.title).font(.subheadline).lineLimit(1)
                                            .frame(width: 130, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                }
            }

            Section("Songs") {
                ForEach(Array(artist.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, onPlay: { player.play(tracks: artist.tracks, startAt: index) })
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
