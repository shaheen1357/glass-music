import SwiftUI

// MARK: - Library root (Apple Music layout: menu rows + Recently Added)
struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var stats: PlayStatsStore
    @State private var showSettings = false

    private var recentlyPlayedTracks: [Track] { stats.recentlyPlayed(from: library.tracks) }
    private var mostPlayedTracks: [Track] { stats.mostPlayed(from: library.tracks) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PlaylistsView() } label: {
                        LibraryMenuRow(icon: "music.note.list", title: "Playlists")
                    }
                    NavigationLink { ArtistsView() } label: {
                        LibraryMenuRow(icon: "music.mic", title: "Artists")
                    }
                    NavigationLink { AlbumsView() } label: {
                        LibraryMenuRow(icon: "square.stack", title: "Albums")
                    }
                    NavigationLink { SongsView(title: "Songs", tracks: library.tracks) } label: {
                        LibraryMenuRow(icon: "music.note", title: "Songs")
                    }
                    NavigationLink { FolderBrowseView(directory: library.documentsURL, title: "Folders") } label: {
                        LibraryMenuRow(icon: "folder", title: "Folders")
                    }
                }

                if !recentlyPlayedTracks.isEmpty {
                    Section {
                        NavigationLink { SongsView(title: "Recently Played", tracks: recentlyPlayedTracks) } label: {
                            LibraryMenuRow(icon: "clock.arrow.circlepath", title: "Recently Played")
                        }
                        NavigationLink { SongsView(title: "Most Played", tracks: mostPlayedTracks) } label: {
                            LibraryMenuRow(icon: "chart.bar.fill", title: "Most Played")
                        }
                    }
                }

                if !library.albums.isEmpty {
                    Section {
                        RecentlyAddedGrid(albums: recentlyAdded)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("Recently Added")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .textCase(nil)
                    }
                }

                if library.tracks.isEmpty && !library.isScanning {
                    EmptyLibraryHint()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) { ImportButton() }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(player).environmentObject(library)
            }
            .refreshable { await library.scan() }
            .overlay {
                if library.isScanning && library.tracks.isEmpty { ProgressView("Scanning…") }
            }
        }
    }

    private var recentlyAdded: [Album] {
        Array(library.albums.sorted { $0.dateAdded > $1.dateAdded }.prefix(6))
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
            Text("Add songs with the + button, or drop files into the Music folder in the Files app, then pull to refresh.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Songs (sortable + searchable)
struct SongsView: View {
    let title: String
    let tracks: [Track]
    @EnvironmentObject var player: PlayerEngine
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
                            ArtworkView(data: album.artworkData, corner: 8).aspectRatio(1, contentMode: .fit)
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
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @State private var addTrack: Track?

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    ArtworkView(data: album.artworkData, corner: 12)
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
    @EnvironmentObject var player: PlayerEngine

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
