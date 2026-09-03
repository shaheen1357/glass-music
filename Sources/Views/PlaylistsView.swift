import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    var coverData: Data? = nil

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
            if let coverData, let ui = UIImage(data: coverData) {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
            } else {
                mosaic
            }
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
    @State private var showImporter = false

    private var m3uTypes: [UTType] {
        [UTType(filenameExtension: "m3u8"), UTType(filenameExtension: "m3u"), .plainText].compactMap { $0 }
    }

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
                Menu {
                    Button { showNew = true } label: { Label("New Playlist", systemImage: "plus") }
                    Button { showImporter = true } label: { Label("Import Playlist (M3U)", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: m3uTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                playlists.importM3U(from: url, library: library)
            }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            PlaylistCover(tracks: playlists.tracks(for: playlist, in: library), kind: playlist.kind,
                          coverData: playlist.coverImageData)
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
    @State private var showEditDetails = false
    @State private var sortMode: PlaylistSort = .custom
    @State private var query = ""
    @State private var editMode: EditMode = .inactive
    @State private var showExported = false
    @State private var exportedURL: URL?

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
                        TrackRow(track: track, onPlay: { player.play(tracks: displayedTracks, startAt: index) })
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
                    if playlist?.kind == .user {
                        Button { showEditDetails = true } label: { Label("Edit Details", systemImage: "pencil") }
                    }
                    Button {
                        if let p = playlist {
                            exportedURL = playlists.exportM3U(p, tracks: storedTracks)
                            showExported = exportedURL != nil
                        }
                    } label: { Label("Export as M3U", systemImage: "square.and.arrow.up") }
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
        .sheet(isPresented: $showEditDetails) {
            EditPlaylistDetailsView(playlistID: playlistID).environmentObject(playlists)
        }
        .alert("Exported", isPresented: $showExported) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Saved \(exportedURL?.lastPathComponent ?? "playlist.m3u8") to Files → On My iPhone → Music.")
        }
    }

    private var totalDuration: Double { storedTracks.reduce(0) { $0 + $1.duration } }

    private var header: some View {
        VStack(spacing: 12) {
            PlaylistCover(tracks: storedTracks, kind: playlist?.kind ?? .user, corner: 12,
                          coverData: playlist?.coverImageData)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text(playlist?.name ?? "").font(.title2.bold()).multilineTextAlignment(.center)
            if let details = playlist?.details, !details.isEmpty {
                Text(details).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("\(songCountString(storedTracks.count)) · \(totalTimeString(totalDuration))")
                .font(.caption).foregroundStyle(.secondary)
            PlayShuffleButtons(tracks: displayedTracks).padding(.top, 4)
            pillRow
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var pillRow: some View {
        HStack(spacing: 10) {
            pill("Add", "plus") { showAddSongs = true }
            if playlist?.kind == .user {
                pill("Edit", "pencil") { showEditDetails = true }
            }
            Menu {
                Picker("Sort By", selection: $sortMode) {
                    ForEach(PlaylistSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { pillLabel("Sort", "arrow.up.arrow.down") }
        }
        .padding(.top, 2)
    }

    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, icon) }.buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.primary)
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


// MARK: - Edit playlist details (name, description, custom cover)
struct EditPlaylistDetailsView: View {
    let playlistID: String
    @EnvironmentObject var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var details = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var loaded = false

    private var playlist: Playlist? { playlists.playlists.first { $0.id == playlistID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Group {
                                if let coverData, let ui = UIImage(data: coverData) {
                                    Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray5))
                                        VStack(spacing: 6) {
                                            Image(systemName: "camera.fill").font(.title2)
                                            Text("Choose Photo").font(.caption)
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(width: 160, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Spacer()
                    }
                    if coverData != nil {
                        Button("Remove Photo", role: .destructive) { coverData = nil }
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Playlist Name", text: $name)
                    TextField("Description", text: $details, axis: .vertical).lineLimit(1...4)
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        playlists.updateDetails(id: playlistID, name: name, details: details)
                        playlists.setCover(coverData, forID: playlistID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !loaded, let p = playlist else { return }
                name = p.name; details = p.details; coverData = p.coverImageData; loaded = true
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    coverData = LibraryStore.thumbnail(from: data, maxDimension: 800) ?? data
                }
            }
        }
    }
}
