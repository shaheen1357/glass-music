import SwiftUI

/// Everything downloaded from the server, in one place: what's coming down, what's
/// waiting for Wi-Fi, what failed (with a retry), and what's on the phone. Songs
/// downloaded one by one swipe away here; songs kept by a downloaded playlist or album
/// are removed from that playlist or album instead.
struct DownloadsView: View {
    @Environment(SubsonicSync.self) private var sync
    @Environment(PlayerEngine.self) private var player
    @State private var confirmRemoveAll = false

    var body: some View {
        let snap = sync.downloadsSnapshot()
        List {
            Section {
                HStack {
                    Label("On This Phone", systemImage: "arrow.down.circle.fill")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: sync.storageSizes.downloads, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                if !snap.waiting.isEmpty {
                    Button("Download Now on Mobile Data") { sync.downloadWaitingOnMobileData() }
                }
            } footer: {
                if !snap.waiting.isEmpty {
                    Text("\(snap.waiting.count) waiting for Wi-Fi. They start on their own when you're on Wi-Fi.")
                }
            }

            if !snap.downloading.isEmpty {
                Section("Downloading") { rows(snap.downloading) }
            }
            if !snap.waiting.isEmpty {
                Section("Waiting for Wi-Fi") { rows(snap.waiting) }
            }
            if !snap.failed.isEmpty {
                Section {
                    rows(snap.failed)
                } header: {
                    HStack {
                        Text("Failed")
                        Spacer()
                        Button("Retry All") { sync.retryFailed() }.font(.caption.bold())
                    }
                }
            }
            Section("Downloaded") {
                if snap.done.isEmpty {
                    Text("Nothing downloaded yet. Use the arrow on a playlist or album, or Download in a song's menu.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                rows(snap.done)
            }
            if !snap.done.isEmpty || !snap.downloading.isEmpty || !snap.waiting.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { sync.removeAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded playlists and albums stop downloading. Songs stay on the server and still stream.")
        }
    }

    @ViewBuilder private func rows(_ tracks: [Track]) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackRow(track: track, onPlay: { player.play(tracks: tracks, startAt: index) })
                .swipeActions {
                    if sync.isManuallyDownloaded(track) {
                        Button(role: .destructive) { sync.removeDownload(track) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
        }
    }
}
