import SwiftUI
import MediaPlayer

// MARK: - Mini player (docked above the tab bar)
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let track = player.currentTrack {
            // Sibling buttons (NOT nested): the expand target and the three
            // transport controls are peers in one HStack. .contentShape on the
            // expand label restores the full-width hit region (incl. the Spacer)
            // that iOS 26's hit-testing regression otherwise strips — the real
            // cause of the flaky tap (Apple DTS fix).
            HStack(spacing: 12) {
                Button { showNowPlaying = true } label: {
                    HStack(spacing: 12) {
                        ArtworkView(id: track.id, data: track.artworkData, corner: 6)
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3).frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 42, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3).frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let frac = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : 0
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * frac, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Full Now Playing screen
struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @EnvironmentObject var playlists: PlaylistStore
    @Binding var isPresented: Bool

    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var showQueue = false
    @State private var showAdd = false
    @State private var showLyrics = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 8)
            artwork
            Spacer(minLength: 8)
            VStack(spacing: 16) {
                trackInfo
                progress
                controls
                bottomBar
                utilityRow
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .preferredColorScheme(.dark)
        .onAppear { scrub = player.currentTime }
        .onChange(of: player.currentTime) { _, newValue in
            if !isScrubbing { scrub = newValue }
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environment(player)
                .environmentObject(playlists)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showAdd) {
            if let t = player.currentTrack {
                AddToPlaylistView(track: t).environmentObject(playlists)
            }
        }
        .sheet(isPresented: $showLyrics) {
            if let t = player.currentTrack {
                LyricsView(track: t).environment(player)
                    .presentationDetents([.large])
                    .presentationBackground(.ultraThinMaterial)
            }
        }
    }

    // Dark scrim guarantees the white controls are always legible, whatever the artwork.
    private var background: some View {
        ZStack {
            if let data = player.currentTrack?.artworkData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .blur(radius: 45)
            } else {
                Color.black.ignoresSafeArea()
            }
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.82)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            Capsule().fill(.white.opacity(0.5)).frame(width: 40, height: 5)
            HStack {
                circleButton("chevron.down") { isPresented = false }
                Spacer()
                Text("Now Playing").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Menu {
                    if let t = player.currentTrack {
                        Button { showAdd = true } label: { Label("Add to a Playlist…", systemImage: "text.badge.plus") }
                        Button { player.playNext(t) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Button { player.addToQueue(t) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
                        Button { playlists.toggleLike(t) } label: {
                            Label(playlists.isLiked(t) ? "Remove from Liked Songs" : "Love",
                                  systemImage: playlists.isLiked(t) ? "heart.slash" : "heart")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.headline).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(.white.opacity(0.18), in: Circle())
                }
            }
        }
        .padding(.top, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { isPresented = false } })
    }

    private func circleButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.18), in: Circle())
        }
    }

    private var artwork: some View {
        ArtworkView(id: player.currentTrack?.id ?? "np", data: player.currentTrack?.artworkData, corner: 16)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300, maxHeight: 300)
            .scaleEffect(player.isPlaying ? 1.0 : 0.86)
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
    }

    private var isLiked: Bool {
        if let track = player.currentTrack { return playlists.isLiked(track) }
        return false
    }

    private var trackInfo: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentTrack?.title ?? "")
                    .font(.title2.bold()).foregroundStyle(.white).lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            Button {
                if let track = player.currentTrack { playlists.toggleLike(track) }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isLiked ? Color.accentColor : .white.opacity(0.85))
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(value: $scrub, in: 0...max(player.duration, 0.1),
                   onEditingChanged: { editing in
                       isScrubbing = editing
                       if !editing { player.seek(to: scrub) }
                   })
            .tint(.white)
            HStack {
                Text(formatTime(scrub))
                Spacer()
                Text("-" + formatTime(max(0, player.duration - scrub)))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var controls: some View {
        HStack {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 54))
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? Color.accentColor : .white.opacity(0.8))
            }
            Spacer()
            VolumeSlider().frame(height: 28).frame(maxWidth: .infinity).padding(.horizontal, 16)
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.8) : Color.accentColor)
            }
        }
        .font(.title3)
        .padding(.top, 4)
    }
}

// MARK: - utility row is defined as an extension member below

extension NowPlayingView {
    var utilityRow: some View {
        HStack {
            Menu {
                Button("Off") { player.cancelSleepTimer() }
                ForEach([5, 10, 15, 30, 45, 60], id: \.self) { m in
                    Button("\(m) minutes") { player.startSleepTimer(minutes: m) }
                }
                Button("End of Track") { player.sleepAtEndOfTrack() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                    if player.sleepTimerMinutes != nil || player.sleepAtTrackEnd {
                        Text(player.sleepStatusText).font(.caption)
                    }
                }
                .foregroundStyle((player.sleepTimerMinutes != nil || player.sleepAtTrackEnd)
                                 ? Color.accentColor : .white.opacity(0.85))
            }
            Spacer()
            Button { showLyrics = true } label: {
                Image(systemName: "quote.bubble").foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").foregroundStyle(.white.opacity(0.85))
            }
        }
        .font(.title3)
        .padding(.top, 2)
    }
}

// MARK: - System volume slider
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = true
        view.tintColor = .white
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Queue (editable: reorder / remove / clear)
struct QueueView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current)
                            .listRowBackground(Color.clear)
                    }
                }
                if player.upNext.isEmpty {
                    Text("Nothing in the queue")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(player.upNext) { track in
                            TrackRow(track: track, onPlay: { player.jump(to: track) })
                                .listRowBackground(Color.clear)
                        }
                            .onDelete { player.removeFromUpNext(at: $0) }
                            .onMove { player.moveUpNext(from: $0, to: $1) }
                    } header: {
                        HStack {
                            Text("Playing Next")
                            Spacer()
                            Button("Clear") { player.clearUpNext() }
                                .font(.subheadline).textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if !player.upNext.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
        }
    }
}
