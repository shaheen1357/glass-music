import SwiftUI
import MediaPlayer

// MARK: - Mini player (docked above the tab bar)
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerEngine
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let track = player.currentTrack {
            HStack(spacing: 12) {
                ArtworkView(data: track.artworkData, corner: 6)
                    .frame(width: 40, height: 40)
                Text(track.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture { showNowPlaying = true }
        }
    }
}

// MARK: - Full Now Playing screen
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerEngine
    @EnvironmentObject var playlists: PlaylistStore
    @Binding var isPresented: Bool

    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var showQueue = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 22) {
                grabber
                Spacer(minLength: 0)
                artwork
                trackInfo
                progress
                controls
                bottomBar
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .onAppear { scrub = player.currentTime }
        .onChange(of: player.currentTime) { _, newValue in
            if !isScrubbing { scrub = newValue }
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(player)
                .environmentObject(playlists)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: pieces
    private var background: some View {
        ZStack {
            if let data = player.currentTrack?.artworkData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .blur(radius: 60)
                    .overlay(Color.black.opacity(0.25))
                    .overlay(.ultraThinMaterial)
                    .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [Color.purple.opacity(0.55), Color.indigo.opacity(0.4), Color.black],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.5))
            .frame(width: 38, height: 5)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture { isPresented = false }
    }

    private var artwork: some View {
        ArtworkView(data: player.currentTrack?.artworkData, corner: 16)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
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
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? "")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
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
            Slider(
                value: $scrub,
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { player.seek(to: scrub) }
                }
            )
            .tint(.white)
            HStack {
                Text(formatTime(scrub))
                Spacer()
                Text("-" + formatTime(max(0, player.duration - scrub)))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var controls: some View {
        HStack {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 54))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
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
            VolumeSlider()
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.white.opacity(0.8))
            }
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.8) : Color.accentColor)
            }
        }
        .font(.title3)
        .padding(.top, 4)
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

// MARK: - Queue
struct QueueView: View {
    @EnvironmentObject var player: PlayerEngine

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        TrackRow(track: current)
                    }
                }
                if !player.upNext.isEmpty {
                    Section("Up Next") {
                        ForEach(player.upNext) { track in
                            TrackRow(track: track)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
