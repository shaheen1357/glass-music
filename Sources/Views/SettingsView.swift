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
}
