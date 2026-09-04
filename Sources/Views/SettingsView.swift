import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    SleepTimerMenu {
                        HStack {
                            Label("Sleep Timer", systemImage: "moon.zzz").foregroundStyle(.primary)
                            Spacer()
                            SleepStatusText().foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Track Transitions") {
                    comingSoon("Gapless Playback", "Removes gaps between tracks.")
                    comingSoon("Crossfade", "Blend the end of one track into the next.")
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
                    Button { Task { await library.scan() } } label: {
                        Label("Rescan Library", systemImage: "arrow.clockwise")
                    }
                }

                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("1.0").foregroundStyle(.secondary) }
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
        }
    }

    private func comingSoon(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text("Coming soon").font(.caption).foregroundStyle(.tertiary)
            }
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
        }
    }
}
