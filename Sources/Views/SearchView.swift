import SwiftUI

struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerEngine
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
                    ContentUnavailableView(
                        "Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Search songs, artists, and albums.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.play(tracks: results, startAt: index)
                            } label: {
                                TrackRow(track: track)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, Songs, Albums")
        }
    }
}
