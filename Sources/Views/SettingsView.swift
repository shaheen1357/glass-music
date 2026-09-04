import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private let sleepChoices = [5, 10, 15, 30, 45, 60]
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    Menu {
                        Button("Off") { player.cancelSleepTimer() }
                        ForEach(sleepChoices, id: \.self) { m in
                            Button("\(m) minutes") { player.startSleepTimer(minutes: m) }
                        }
                        Button("End of Track") { player.sleepAtEndOfTrack() }
                    } label: {
                        HStack {
                            Label("Sleep Timer", systemImage: "moon.zzz").foregroundStyle(.primary)
                            Spacer()
                            Text(player.sleepStatusText).foregroundStyle(.secondary)
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
                    comingSoon("Volume Normalization", "Even out loudness across tracks.")
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Equalizer is live. Volume normalization is next.")
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
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
