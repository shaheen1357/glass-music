import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

enum RepeatMode {
    case off, all, one
}

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    @Published var sleepTimerMinutes: Int? = nil
    @Published var sleepAtTrackEnd = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var originalQueue: [Track] = []
    private var sleepTask: Task<Void, Never>?
    var onPlay: ((Track) -> Void)?

    var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var upNext: [Track] {
        guard currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    init() {
        configureSession()
        setupRemoteCommands()
    }

    // MARK: - Session
    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    // MARK: - Playback control
    func play(tracks: [Track], startAt index: Int) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        originalQueue = tracks
        queue = tracks
        if isShuffled {
            applyShuffle(keeping: index)
        } else {
            currentIndex = index
        }
        startCurrent()
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        onPlay?(track)

        if let timeObserver { player?.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }

        let item = AVPlayerItem(url: track.url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        player = newPlayer

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = CMTimeGetSeconds(time)
                if let itemDuration = self.player?.currentItem?.duration, itemDuration.isNumeric {
                    let secs = CMTimeGetSeconds(itemDuration)
                    if secs.isFinite && secs > 0 { self.duration = secs }
                }
                self.refreshNowPlayingElapsed()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.trackDidEnd() }
        }

        duration = track.duration
        currentTime = 0
        newPlayer.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    private func trackDidEnd() {
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            player?.play()
            isPlaying = true
        case .all, .off:
            advance(auto: true)
        }
    }

    func togglePlayPause() {
        guard let player else {
            if let track = currentTrack {
                play(tracks: queue.isEmpty ? [track] : queue, startAt: currentIndex)
            }
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    func next() { advance(auto: false) }

    private func advance(auto: Bool) {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            startCurrent()
        } else if repeatMode == .all {
            currentIndex = 0
            startCurrent()
        } else {
            player?.pause()
            isPlaying = false
            seek(to: 0)
            updateNowPlayingInfo()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            currentIndex -= 1
            startCurrent()
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player?.seek(to: target)
        currentTime = max(0, seconds)
        refreshNowPlayingElapsed()
    }

    // MARK: - Shuffle / repeat
    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentTrack else { return }
        if isShuffled {
            applyShuffle(keeping: currentIndex)
        } else {
            queue = originalQueue
            currentIndex = queue.firstIndex(of: current) ?? 0
        }
    }

    private func applyShuffle(keeping index: Int) {
        guard queue.indices.contains(index) else { return }
        let current = queue[index]
        var rest = queue
        rest.remove(at: index)
        rest.shuffle()
        queue = [current] + rest
        currentIndex = 0
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Queue editing
    func addToQueue(_ track: Track) {
        if queue.isEmpty { play(tracks: [track], startAt: 0) }
        else { queue.append(track); updateNowPlayingInfo() }
    }

    func playNext(_ track: Track) {
        if queue.isEmpty { play(tracks: [track], startAt: 0) }
        else { queue.insert(track, at: min(currentIndex + 1, queue.count)) }
    }

    func removeFromUpNext(at offsets: IndexSet) {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        var up = upNext
        up.remove(atOffsets: offsets)
        queue = Array(queue[0...currentIndex]) + up
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        var up = upNext
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[0...currentIndex]) + up
    }

    func clearUpNext() {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        queue = Array(queue[0...currentIndex])
    }

    func jump(to track: Track) {
        guard let idx = queue.firstIndex(of: track) else { return }
        currentIndex = idx
        startCurrent()
    }

    // MARK: - Sleep timer
    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerMinutes = minutes
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard let self, !Task.isCancelled else { return }
            self.player?.pause()
            self.isPlaying = false
            self.updateNowPlayingInfo()
            self.sleepTimerMinutes = nil
            self.sleepTask = nil
        }
    }

    func sleepAtEndOfTrack() {
        cancelSleepTimer()
        sleepAtTrackEnd = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerMinutes = nil
        sleepAtTrackEnd = false
    }

    var sleepStatusText: String {
        if let minutes = sleepTimerMinutes { return "\(minutes) min" }
        if sleepAtTrackEnd { return "End of Track" }
        return "Off"
    }

    // MARK: - Now Playing info / remote commands
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func resume() {
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let image = track.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlayingElapsed() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }
}
