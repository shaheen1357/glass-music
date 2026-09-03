import SwiftUI

enum PlaylistListSort: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case title = "Title"
    var id: String { rawValue }
}

// MARK: - Cover art (gradient tiles + 4-up mosaic)
struct PlaylistCover: View {
    let tracks: [Track]
    let kind: PlaylistKind
    var corner: CGFloat = 8

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .liked:
            ZStack {
                LinearGradient(colors: [Color(red: 0.45, green: 0.18, blue: 0.9),
                                        Color(red: 0.95, green: 0.25, blue: 0.55)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                Image(systemName: "heart.fill").font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
            }
        case .podcasts:
            ZStack {
                LinearGradient(colors: [Color(red: 0.12, green: 0.5, blue: 0.42),
                                        Color(red: 0.08, green: 0.28, blue: 0.5)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                Image(systemName: "mic.fill").font(.system(size: 28, weight: .medium)).foregroundStyle(.white)
            }
        case .user:
            mosaic
        }
    }

    @ViewBuilder private var mosaic: some View {
        let arts = Array(tracks.prefix(4)).map { $0.artworkData }
        if arts.isEmpty || arts.allSatisfy({ $0 == nil }) {
            ZStack {
                Color(.systemGray5)
                Image(systemName: "music.note.list").font(.title2).foregroundStyle(.secondary)
            }
        } else if arts.count < 4 {
            ArtworkView(data: arts.first ?? nil, corner: 0)
        } else {
            GeometryReader { geo in
                let s = geo.size.width / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(data: arts[0], corner: 0).frame(width: s, height: s)
                        ArtworkView(data: arts[1], corner: 0).frame(width: s, height: s)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(data: arts[2], corner: 0).frame(width: s, height: s)
                        ArtworkView(data: arts[3], corner: 0).frame(width: s, height: s)
                    }
                }
            }
        }
    }
}

// MARK: - Playlists list (Apple Music rows + Spotify function: sort/search/pin/new)
struct PlaylistsView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var library: LibraryStore
    @State private var sort: PlaylistListSort = .recentlyAdded
    @State private var query = ""
    @State private var showNew = false

    private var displayed: [Playlist] {
        let all = playlists.playlists
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let pinned = filtered.filter { $0.isPinned }
        let systemRows = filtered.filter { !$0.isPinned && $0.kind != .user }
        var userRest = filtered.filter { !$0.isPinned && $0.kind == .user }
        switch sort {
        case .title: userRest.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlyAdded: userRest.reverse()
        }
        return pinned + systemRows + userRest
    }

    var body: some View {
        List {
            ForEach(displayed) { playlist in
                NavigationLink { PlaylistDetailView(playlistID: playlist.id) } label: {
                    row(playlist)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { playlists.togglePin(playlist) } label: {
                        Label(playlist.isPinned ? "Unpin" : "Pin",
                              systemImage: playlist.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing) {
                    if playlist.kind == .user {
                        Button(role: .destructive) { playlists.delete(playlist) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    Button { playlists.togglePin(playlist) } label: {
                        Label(playlist.isPinned ? "Unpin" : "Pin to Top",
                              systemImage: playlist.isPinned ? "pin.slash" : "pin")
                    }
                    if playlist.kind == .user {
                        Button(role: .destructive) { playlists.delete(playlist) } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find in Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(PlaylistListSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
        }
        .sheet(isPresented: $showNew) {
            NewPlaylistSheet { name in _ = playlists.createPlaylist(name: name) }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            PlaylistCover(tracks: playlists.tracks(for: playlist, in: library), kind: playlist.kind)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if playlist.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.accentColor)
                    }
                    Text(playlist.name).font(.body)
                }
                Text(subtitle(playlist)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ playlist: Playlist) -> String {
        let n = playlist.trackIDs.count
        switch playlist.kind {
        case .podcasts: return n == 1 ? "1 episode" : "\(n) episodes"
        default: return "Playlist · " + (n == 1 ? "1 song" : "\(n) songs")
        }
    }
}

// MARK: - Playlist detail (Apple Music look + Spotify function)
struct PlaylistDetailView: View {
    let playlistID: String
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
    @State private var showAddSongs = false
    @State private var sortMode: PlaylistSort = .custom
    @State private var query = ""
    @State private var editMode: EditMode = .inactive

    private var playlist: Playlist? { playlists.playlists.first { $0.id == playlistID } }
    private var storedTracks: [Track] { playlist.map { playlists.tracks(for: $0, in: library) } ?? [] }

    private var canReorder: Bool { sortMode == .custom && query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var displayedTracks: [Track] {
        var items = storedTracks
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter {
                $0.title.localizedCaseInsensitiveContains(q) ||
                $0.artist.localizedCaseInsensitiveContains(q) ||
                $0.album.localizedCaseInsensitiveContains(q)
            }
        }
        switch sortMode {
        case .custom: break
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: items.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album: items.sort { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .recentlyAdded: items.reverse()
        }
        return items
    }

    private var suggestions: [Track] {
        guard playlist?.kind != .podcasts else { return [] }
        let existing = Set(playlist?.trackIDs ?? [])
        if storedTracks.isEmpty {
            return Array(library.tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(10))
        }
        let artists = Set(storedTracks.map { $0.artist })
        let albums = Set(storedTracks.map { $0.album })
        let candidates = library.tracks.filter {
            !existing.contains($0.id) && (artists.contains($0.artist) || albums.contains($0.album))
        }
        return Array(candidates.prefix(12))
    }

    var body: some View {
        List {
            Section {
                header.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }

            if displayedTracks.isEmpty {
                Text(query.isEmpty ? "No songs yet. Use ••• → Add Songs." : "No matches.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                        Button { player.play(tracks: displayedTracks, startAt: index) } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { displayedTracks[$0].id }
                            .forEach { playlists.removeTrack(id: $0, from: playlistID) }
                    }
                    .onMove { source, destination in
                        guard canReorder else { return }
                        playlists.moveTracks(from: source, to: destination, in: playlistID)
                    }
                }
            }

            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { track in
                        HStack(spacing: 12) {
                            ArtworkView(data: track.artworkData, corner: 6).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).lineLimit(1)
                                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { playlists.add(track, to: playlistID) } label: {
                                Image(systemName: "plus.circle").font(.title3).foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Suggested Songs").font(.headline).textCase(nil).foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Find in Playlist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAddSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                    Picker("Sort By", selection: $sortMode) {
                        ForEach(PlaylistSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if canReorder && !storedTracks.isEmpty {
                        Button {
                            withAnimation { editMode = editMode == .active ? .inactive : .active }
                        } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showAddSongs) {
            AddSongsView(playlistID: playlistID)
                .environmentObject(playlists)
                .environmentObject(library)
                .environmentObject(player)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            PlaylistCover(tracks: storedTracks, kind: playlist?.kind ?? .user, corner: 12)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text(playlist?.name ?? "").font(.title2.bold()).multilineTextAlignment(.center)
            PlayShuffleButtons(tracks: displayedTracks)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Add songs to a playlist (searchable)
struct AddSongsView: View {
    let playlistID: String
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var justAdded: Set<String> = []

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }

    private var existing: Set<String> {
        Set(playlists.playlists.first { $0.id == playlistID }?.trackIDs ?? [])
    }

    var body: some View {
        NavigationStack {
            List(results) { track in
                let inList = existing.contains(track.id) || justAdded.contains(track.id)
                Button {
                    playlists.add(track, to: playlistID)
                    justAdded.insert(track.id)
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(data: track.artworkData, corner: 6).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1).foregroundStyle(.primary)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: inList ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundStyle(inList ? Color.accentColor : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(inList)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Find in library")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Add one track to a chosen playlist (from context menu)
struct AddToPlaylistView: View {
    let track: Track
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false

    private var targets: [Playlist] { playlists.playlists.filter { $0.kind != .podcasts } }

    var body: some View {
        NavigationStack {
            List {
                Button { showNew = true } label: {
                    Label("New Playlist", systemImage: "plus").foregroundStyle(Color.accentColor)
                }
                ForEach(targets) { playlist in
                    Button {
                        playlists.add(track, to: playlist.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: playlist.systemIcon).foregroundStyle(Color.accentColor).frame(width: 26)
                            Text(playlist.name).foregroundStyle(.primary)
                            Spacer()
                            if playlist.trackIDs.contains(track.id) {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showNew) {
                NewPlaylistSheet { name in
                    let created = playlists.createPlaylist(name: name)
                    playlists.add(track, to: created.id)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - New playlist sheet
struct NewPlaylistSheet: View {
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form { TextField("Playlist Name", text: $name).textInputAutocapitalization(.words) }
                .navigationTitle("New Playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Create") { onCreate(name); dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }
        .presentationDetents([.height(200)])
    }
}
