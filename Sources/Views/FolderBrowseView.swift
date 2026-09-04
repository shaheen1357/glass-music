import SwiftUI

// Browse the on-disk folder tree (owned-library users organize by folders).
struct FolderBrowseView: View {
    let directory: URL
    let title: String
    @EnvironmentObject var library: LibraryStore
    @Environment(PlayerEngine.self) private var player

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "aif", "aiff", "caf", "m4b", "ogg"
    ]

    private var contents: (folders: [URL], files: [URL]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return ([], []) }
        var folders: [URL] = [], files: [URL] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { folders.append(item) }
            else if Self.audioExtensions.contains(item.pathExtension.lowercased()) { files.append(item) }
        }
        folders.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        files.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return (folders, files)
    }

    var body: some View {
        let items = contents
        let map = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tracks = items.files.compactMap { map[$0.path] }

        List {
            if items.folders.isEmpty && tracks.isEmpty {
                Text("This folder has no music.")
                    .foregroundStyle(.secondary).listRowSeparator(.hidden)
            }
            ForEach(items.folders, id: \.self) { folder in
                NavigationLink {
                    FolderBrowseView(directory: folder, title: folder.lastPathComponent)
                } label: {
                    Label(folder.lastPathComponent, systemImage: "folder.fill")
                }
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, onPlay: { player.play(tracks: tracks, startAt: index) })
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
