import SwiftUI

struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var history: SearchHistoryStore
    @State private var query = ""

    private var results: [Track] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let q = query.lowercased()
        return library.tracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }

    private struct BrowseCat: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let colors: [Color]
    }
    private let browseCats: [BrowseCat] = [
        .init(title: "Playlists", icon: "music.note.list", colors: [Color(red: 0.90, green: 0.20, blue: 0.50), Color(red: 0.50, green: 0.10, blue: 0.60)]),
        .init(title: "Artists", icon: "music.mic", colors: [Color(red: 0.95, green: 0.50, blue: 0.20), Color(red: 0.85, green: 0.20, blue: 0.25)]),
        .init(title: "Albums", icon: "square.stack", colors: [Color(red: 0.20, green: 0.50, blue: 0.90), Color(red: 0.10, green: 0.60, blue: 0.70)]),
        .init(title: "Songs", icon: "music.note", colors: [Color(red: 0.20, green: 0.70, blue: 0.45), Color(red: 0.10, green: 0.50, blue: 0.50)]),
        .init(title: "Recently Added", icon: "clock", colors: [Color(red: 0.35, green: 0.30, blue: 0.80), Color(red: 0.20, green: 0.30, blue: 0.60)]),
        .init(title: "Folders", icon: "folder", colors: [Color(red: 0.60, green: 0.42, blue: 0.22), Color(red: 0.82, green: 0.52, blue: 0.22)]),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    emptyState
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, onPlay: { player.play(tracks: results, startAt: index) })
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, Songs, Albums")
            .onSubmit(of: .search) { history.add(query) }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !history.recent.isEmpty { recentSearches }
                browse
            }
            .padding(.vertical, 8)
        }
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent Searches").font(.title3.bold())
                Spacer()
                Button("Clear") { history.clear() }.font(.subheadline)
            }
            .padding(.horizontal)
            ForEach(history.recent, id: \.self) { q in
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(q).foregroundStyle(.primary)
                    Spacer()
                    Button { history.remove(q) } label: {
                        Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading)
                .contentShape(Rectangle())
                .onTapGesture { query = q }
            }
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browse").font(.title3.bold()).padding(.horizontal)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(browseCats) { cat in
                    NavigationLink { destination(cat) } label: { card(cat) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func card(_ cat: BrowseCat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: cat.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(cat.title).font(.headline).foregroundStyle(.white).padding(12)
            Image(systemName: cat.icon)
                .font(.title)
                .foregroundStyle(.white.opacity(0.9))
                .rotationEffect(.degrees(25))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 6, y: 10)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func destination(_ cat: BrowseCat) -> some View {
        switch cat.title {
        case "Playlists": PlaylistsView()
        case "Artists": ArtistsView()
        case "Albums": AlbumsView()
        case "Songs": SongsView(title: "Songs", tracks: library.tracks)
        case "Recently Added":
            SongsView(title: "Recently Added", tracks: library.tracks.sorted { $0.dateAdded > $1.dateAdded })
        case "Folders": FolderBrowseView(directory: library.documentsURL, title: "Folders")
        default: EmptyView()
        }
    }
}
