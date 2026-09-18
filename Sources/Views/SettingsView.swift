import SwiftUI
import UniformTypeIdentifiers

private struct ExportItem: Identifiable { let id = UUID(); let url: URL }

struct SettingsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var stats: PlayStatsStore
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var exportItem: ExportItem?
    @State private var showRestore = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SleepTimerMenu {
                        HStack {
                            Label("Sleep Timer", systemImage: "moon.zzz").foregroundStyle(.primary)
                            Spacer()
                            SleepStatusText().foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { player.autoplayEnabled },
                        set: { player.setAutoplayEnabled($0) }
                    )) {
                        Label("Autoplay", systemImage: "infinity").foregroundStyle(.primary)
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("When your music runs out, Autoplay keeps going with similar songs.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { player.gaplessEnabled },
                        set: { player.setGaplessEnabled($0) }
                    )) {
                        Label("Gapless Playback", systemImage: "arrow.right.to.line").foregroundStyle(.primary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Crossfade", systemImage: "wave.3.forward").foregroundStyle(.primary)
                            Spacer()
                            Text(player.crossfadeDuration < 1 ? "Off" : "\(Int(player.crossfadeDuration))s")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { player.crossfadeDuration },
                            set: { player.setCrossfadeDuration($0) }
                        ), in: 0...12, step: 1)
                    }
                } header: {
                    Text("Track Transitions")
                } footer: {
                    Text("Gapless removes the silence between tracks. Crossfade blends the end of one track into the start of the next; while it's on it takes over from gapless.")
                }

                Section {
                    NavigationLink {
                        EqualizerView()
                    } label: {
                        Label("Equalizer", systemImage: "slider.vertical.3").foregroundStyle(.primary)
                    }
                    Toggle(isOn: Binding(
                        get: { player.normalizationEnabled },
                        set: { player.setNormalizationEnabled($0) }
                    )) {
                        Label("Volume Normalization", systemImage: "speaker.wave.2").foregroundStyle(.primary)
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Volume normalization learns each track's loudness the first time you play it, then evens it out from the next play on.")
                }

                Section("Library") {
                    HStack {
                        Label("Songs", systemImage: "music.note")
                        Spacer()
                        Text("\(library.tracks.count)").foregroundStyle(.secondary)
                    }
                    Button { showImport = true } label: {
                        Label("Import Songs", systemImage: "square.and.arrow.down")
                    }
                    Button { Task { await library.scan(force: true) } } label: {
                        Label("Rescan Library", systemImage: "arrow.clockwise")
                    }
                    Button { Task { await library.fetchMissingArtwork() } } label: {
                        Label(library.isFetchingArtwork ? "Fetching Artwork…" : "Fetch Missing Artwork",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(library.isFetchingArtwork)
                }

                Section {
                    Button {
                        if let url = BackupService.makeFile(playlists: playlists, stats: stats) {
                            exportItem = ExportItem(url: url)
                        }
                    } label: {
                        Label("Export Backup", systemImage: "square.and.arrow.up").foregroundStyle(.primary)
                    }
                    Button { showRestore = true } label: {
                        Label("Restore from Backup", systemImage: "arrow.down.doc").foregroundStyle(.primary)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Saves your playlists, Liked Songs and play history to a file you can keep or move to a new phone. Your music files aren't included — they rebuild from the Music folder.")
                }

                Section("About") {
                    HStack {
                        Text("Version"); Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("Local hi-res player · FLAC, ALAC, AAC, MP3, WAV, AIFF")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showImport,
                          allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .sheet(item: $exportItem) { ActivityView(items: [$0.url]) }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let ok = BackupService.restore(from: url, playlists: playlists, stats: stats)
                    if ok { Haptics.success() }
                    restoreMessage = ok ? "Backup restored." : "Couldn't read that backup file."
                }
            }
            .alert("Restore", isPresented: Binding(get: { restoreMessage != nil },
                                                   set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(restoreMessage ?? "") }
        }
    }
}
