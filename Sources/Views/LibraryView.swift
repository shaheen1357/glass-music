import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library ("Your Library" — Spotify layout, Apple aesthetics)
enum LibraryFilter: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var stats: PlayStatsStore

    @State private var filter: LibraryFilter = .playlists
    @State private var query = ""
    @State private var isGrid = false
    @State private var sort: ItemSort = .recentlyAdded
    @State private var showNewPlaylist = false

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                content
            }
            .navigationTitle("Your Library")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find in Library")
            .toolbar {
                if filter == .albums || filter == .songs {
                    ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) }
                }
                if filter == .playlists || filter == .albums {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { withAnimation { isGrid.toggle() } } label: {
                            Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewPlaylist = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showNewPlaylist) {
                NewPlaylistSheet { name in _ = playlists.createPlaylist(name: name) }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { f in
                    let selected = f == filter
                    Text(f.rawValue)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if selected { Capsule().fill(Color.accentColor) }
                            else { Capsule().fill(.ultraThinMaterial) }
                        }
                        .foregroundStyle(selected ? .white : .primary)
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { filter = f } }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var content: some View {
        switch filter {
        case .playlists: playlistsContent
        case .artists: artistsContent
        case .albums: albumsContent
        case .songs: songsContent
        }
    }

    // MARK: Playlists
    private var displayedPlaylists: [Playlist] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = q.isEmpty ? playlists.playlists
            : playlists.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return all.filter { $0.isPinned } + all.filter { !$0.isPinned }
    }

    @ViewBuilder private var playlistsContent: some View {
        if isGrid {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(displayedPlaylists) { pl in
                        NavigationLink { PlaylistDetailView(playlistID: pl.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PlaylistCover(tracks: playlists.tracks(for: pl, in: library),
                                              kind: pl.kind, coverData: pl.coverImageData)
                                    .aspectRatio(1, contentMode: .fit)
                                Text(pl.name).font(.subheadline).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        } else {
            List {
                ForEach(displayedPlaylists) { pl in
                    NavigationLink { PlaylistDetailView(playlistID: pl.id) } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(tracks: playlists.tracks(for: pl, in: library),
                                          kind: pl.kind, coverData: pl.coverImageData)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if pl.isPinned {
                                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.accentColor)
                                    }
                                    Text(pl.name)
                                }
                                Text(pl.kind == .podcasts ? "\(playlists.tracks(for: pl, in: library).count) episodes"
                                                          : "Playlist · \(playlists.tracks(for: pl, in: library).count) songs")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { playlists.togglePin(pl) } label: {
                            Label(pl.isPinned ? "Unpin" : "Pin", systemImage: pl.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        if pl.kind == .user {
                            Button(role: .destructive) { playlists.delete(pl) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Artists
    private var displayedArtists: [ArtistGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? library.artists
            : library.artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var artistsContent: some View {
        List {
            ForEach(displayedArtists) { artist in
                NavigationLink { ArtistDetailView(artist: artist) } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color(.systemGray5))
                            Image(systemName: "music.mic").foregroundStyle(.secondary)
                        }
                        .frame(width: 48, height: 48)
                        Text(artist.name)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: Albums
    private var displayedAlbums: [Album] {
        var items = library.albums
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }
        }
        switch sort {
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: items.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .recentlyAdded: items.sort { $0.dateAdded > $1.dateAdded }
        }
        return items
    }
    @ViewBuilder private var albumsContent: some View {
        if isGrid {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedAlbums) { album in
                        NavigationLink { AlbumDetailView(album: album) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(id: album.id, data: album.artworkData, corner: 8).aspectRatio(1, contentMode: .fit)
                                Text(album.title).font(.subheadline).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        } else {
            List {
                ForEach(displayedAlbums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        HStack(spacing: 12) {
                            ArtworkView(id: album.id, data: album.artworkData, corner: 6).frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.title).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Songs
    private var displayedSongs: [Track] {
        var items = library.tracks
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }
        }
        switch sort {
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: items.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .recentlyAdded: items.sort { $0.dateAdded > $1.dateAdded }
        }
        return items
    }
    private var songsContent: some View {
        List {
            ForEach(Array(displayedSongs.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, onPlay: { player.play(tracks: displayedSongs, startAt: index) })
            }
        }
        .listStyle(.plain)
    }
}


struct LibraryMenuRow: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(title).font(.title3).foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyLibraryHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No music yet").font(.headline)
            Text("Import songs from Settings (gear on the Home tab), or drop files into the Music folder in the Files app, then pull to refresh.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Songs (sortable + searchable)
struct SongsView: View {
    let title: String
    let tracks: [Track]
    @Environment(PlayerEngine.self) private var player
    @State private var sort: ItemSort = .title
    @State private var query = ""

    private var displayed: [Track] {
        var items = tracks
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
            }
        }
        switch sort {
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: items.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .recentlyAdded: items.sort { $0.dateAdded > $1.dateAdded }
        }
        return items
    }

    var body: some View {
        List {
            ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, onPlay: { player.play(tracks: displayed, startAt: index) })
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find in \(title)")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) } }
    }
}

// MARK: - Albums (sortable grid + searchable)
struct AlbumsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var sort: ItemSort = .title
    @State private var query = ""
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var displayed: [Album] {
        var items = library.albums
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
            }
        }
        switch sort {
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: items.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .recentlyAdded: items.sort { $0.dateAdded > $1.dateAdded }
        }
        return items
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(displayed) { album in
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
            .padding()
        }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find in Albums")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { SortMenu(selection: $sort) } }
    }
}

// MARK: - Album detail (Apple Music look)
struct AlbumDetailView: View {
    let album: Album
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @State private var addTrack: Track?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    ArtworkView(id: album.id, data: album.artworkData, corner: 12)
                        .frame(width: 220, height: 220)
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                    VStack(spacing: 4) {
                        Text(album.title).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                    }
                    PlayShuffleButtons(tracks: album.tracks)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 8) {
                        Button { player.play(tracks: album.tracks, startAt: index) } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(track.title)
                                    .foregroundStyle(player.currentTrack?.id == track.id ? Color.accentColor : .primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatTime(track.duration)).font(.footnote).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Menu {
                            TrackActions(track: track,
                                         onPlay: { player.play(tracks: album.tracks, startAt: index) },
                                         onAddToPlaylist: { addTrack = track })
                        } label: {
                            TrackMenuLabel()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("\(songCountString(album.tracks.count)) · \(totalTimeString(album.tracks.reduce(0) { $0 + $1.duration }))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $addTrack) { AddToPlaylistView(track: $0).environmentObject(playlists) }
    }
}

// MARK: - Artists (searchable)
struct ArtistsView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var query = ""

    private var displayed: [ArtistGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            ForEach(displayed) { artist in
                NavigationLink { ArtistDetailView(artist: artist) } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(Color(.systemGray5))
                            Image(systemName: "music.mic").foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name).lineLimit(1)
                            Text(artist.tracks.count == 1 ? "1 song" : "\(artist.tracks.count) songs")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find in Artists")
    }
}

// MARK: - Reusable bits
struct SortMenu: View {
    @Binding var selection: ItemSort
    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(ItemSort.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }
}

struct PlayShuffleButtons: View {
    let tracks: [Track]
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if player.isShuffled { player.toggleShuffle() }
                player.play(tracks: tracks, startAt: 0)
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button {
                guard !tracks.isEmpty else { return }
                if !player.isShuffled { player.toggleShuffle() }
                player.play(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Color.accentColor.opacity(0.15))
        .foregroundStyle(Color.accentColor)
        .disabled(tracks.isEmpty)
    }
}
