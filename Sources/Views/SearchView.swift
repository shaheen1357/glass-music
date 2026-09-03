import SwiftUI

struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
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

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    if history.recent.isEmpty {
                        ContentUnavailableView(
                            "Find in Your Library",
                            systemImage: "magnifyingglass",
                            description: Text("Search songs, artists, and albums.")
                        )
                    } else {
                        List {
                            Section {
                                ForEach(history.recent, id: \.self) { q in
                                    Button { query = q } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                            Text(q).foregroundStyle(.primary)
                                            Spacer()
                                            Button { history.remove(q) } label: {
                                                Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack {
                                    Text("Recent Searches")
                                    Spacer()
                                    Button("Clear") { history.clear() }.font(.subheadline).textCase(nil)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
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
}
