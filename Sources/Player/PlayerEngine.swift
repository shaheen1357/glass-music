import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Observation

enum RepeatMode {
    case off, all, one
}

@MainActor
@Observable
final class PlayerEngine {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var repeatMode: RepeatMode = .off
    var isShuffled = false
    var sleepTimerMinutes: Int? = nil
    private(set) var sleepEndDate: Date? = nil    // for a live countdown in the UI
    var sleepAtTrackEnd = false

    // MARK: Audio engine graph  (playerNode -> eq -> normGain -> mainMixer -> output)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var currentFormat: AVAudioFormat?
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    // Per-track normalization gain. A 0-band EQ is just a globalGain node that can
    // boost as well as attenuate (playerNode.volume can't exceed 1.0).
    private let normGain = AVAudioUnitEQ(numberOfBands: 0)

    // MARK: EQ (user-facing state; tracked by @Observable so the UI reflects it)
    static let eqBandLabels = ["32 Hz", "64 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]
    private static let eqCenters: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    struct EQPreset: Identifiable {
        var id: String { name }
        let name: String
        let gains: [Float]
    }
    static let eqPresets: [EQPreset] = [
        EQPreset(name: "Flat",         gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost",   gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 3, 5, 6]),
        EQPreset(name: "Vocal",        gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        EQPreset(name: "Loudness",     gains: [5, 4, 1, 0, -1, -1, 0, 2, 4, 5]),
        EQPreset(name: "Acoustic",     gains: [4, 3, 2, 0, 1, 1, 3, 3, 2, 1])
    ]
    private(set) var eqEnabled = false
    private(set) var eqGains: [Float] = Array(repeating: 0, count: 10)

    // MARK: Volume normalization
    private(set) var normalizationEnabled = false

    // MARK: Playback bookkeeping
    private var audioFile: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var audioLengthSamples: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0        // where the current schedule started
    private var pausedFrame: AVAudioFramePosition?         // frozen playhead while paused
    private var scheduleGeneration = 0                     // guards stale completion callbacks
    private var isSuspended = false                        // true across interruption / device-loss
    private var needsReschedule = false                    // set after a media-services reset
    private var displayTimer: Timer?

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
        engine.attach(playerNode)
        engine.attach(eq)
        engine.attach(normGain)
        setupEQBands()
        loadEQSettings()
        loadNormalizationSetting()
        configureSession()
        setupRemoteCommands()
    }

    // MARK: - Session & engine lifecycle
    private func configureSession() {
        activateSession()
        let session = AVAudioSession.sharedInstance()
        // Phone calls / Siri / alarms.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in Task { @MainActor in self?.handleInterruption(note) } }
        // Headphones / Bluetooth / DAC unplug.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] note in Task { @MainActor in self?.handleRouteChange(note) } }
        // Route/format change — the engine has already stopped; we must restart it.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleConfigurationChange() } }
        // Media services reset — every audio object is invalid; rebuild in place.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleMediaServicesReset() } }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Connect (or reconnect) the graph for a given file format. The player node
    /// must be stopped before calling this.
    private func wire(_ format: AVAudioFormat) {
        engine.connect(playerNode, to: eq, format: format)
        engine.connect(eq, to: normGain, format: format)
        engine.connect(normGain, to: engine.mainMixerNode, format: format)
    }

    private func connectGraph(format: AVAudioFormat) {
        if let cur = currentFormat,
           cur.sampleRate == format.sampleRate,
           cur.channelCount == format.channelCount { return }
        currentFormat = format
        wire(format)
    }

    // MARK: - Interruption / route / config handling
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isSuspended = true                 // Core Audio already stopped the engine
            pausedFrame = currentFrame
            isPlaying = false
            stopDisplayTimer()
            updateNowPlayingInfo()
        case .ended:
            isSuspended = false
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                restartAndResume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            // Headphones/DAC pulled: pause and suppress the trailing config-change
            // auto-restart so we don't blast the speaker.
            isSuspended = true
            pause()
        }
    }

    private func handleConfigurationChange() {
        // Fires after route/format changes (and as a side effect of interruptions).
        guard !isSuspended, isPlaying, audioFile != nil else { return }
        restartAndResume()
    }

    private func handleMediaServicesReset() {
        // Everything is invalid. Reuse the SAME engine instance (a new one would
        // crash on re-attach). Reactivate the session, reconnect, leave paused.
        activateSession()
        pausedFrame = currentFrame
        isPlaying = false
        stopDisplayTimer()
        if let fmt = currentFormat { wire(fmt); reapplyGraphParams() }
        needsReschedule = true
        updateNowPlayingInfo()
    }

    private func restartAndResume() {
        guard audioFile != nil, sampleRate > 0 else { return }
        // currentTime is the last position the timer published; the render clock
        // may already be gone by the time a config-change notification arrives.
        let resumeFrame = min(max(0, AVAudioFramePosition(max(0, currentTime) * sampleRate)), audioLengthSamples)
        do {
            activateSession()
            if let fmt = currentFormat { wire(fmt); reapplyGraphParams() }
            try startEngineIfNeeded()
            playerNode.stop()
            seekFrame = resumeFrame
            pausedFrame = nil
            scheduleSegment(from: resumeFrame)
            playerNode.play()
            isPlaying = true
            startDisplayTimer()
            updateNowPlayingInfo()
        } catch {
            print("Engine restart failed: \(error)")
        }
    }

    // MARK: - Time tracking
    /// Frames rendered by the node since its current schedule started.
    private var renderedFrames: AVAudioFramePosition {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return playerTime.sampleTime
    }

    /// Absolute playhead in frames (frozen at `pausedFrame` while paused).
    private var currentFrame: AVAudioFramePosition {
        if let pf = pausedFrame { return max(0, min(pf, audioLengthSamples)) }
        return max(0, min(seekFrame + renderedFrames, audioLengthSamples))
    }

    private func startDisplayTimer() {
        stopDisplayTimer()
        // Default run-loop mode: the timer pauses during scroll tracking, so we
        // don't publish currentTime (and re-render views) mid-scroll.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCurrentTime() }
        }
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func updateCurrentTime() {
        guard sampleRate > 0 else { return }
        currentTime = Double(currentFrame) / sampleRate
        // Don't rewrite Now Playing elapsed/rate every tick — the system
        // extrapolates position between discrete writes, and per-tick writes get
        // throttled and desync the lock screen in long background sessions. We set
        // elapsed on discrete events only (play / pause / seek / track change).
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

    /// Start a fresh context in listed order (shuffle off). Use for "Play".
    func playInOrder(_ tracks: [Track], startAt index: Int = 0) {
        isShuffled = false
        play(tracks: tracks, startAt: index)
    }

    /// Start a fresh context shuffled (shuffle on), from a random first track.
    /// Use for "Shuffle" buttons — sets the mode and plays in one shot instead of
    /// toggling shuffle on the outgoing queue first (which disturbed it needlessly).
    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        isShuffled = true
        play(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        onPlay?(track)
        isSuspended = false
        needsReschedule = false
        playerNode.stop()                       // fires a stale completion...
        scheduleGeneration &+= 1                // ...neutralize it even if the load below fails

        do {
            let file = try AVAudioFile(forReading: track.url)
            audioFile = file
            sampleRate = file.processingFormat.sampleRate
            audioLengthSamples = file.length
            // #3: a zero-length/degenerate file would "play" forever (no completion) — bail.
            guard audioLengthSamples > 0 else {
                audioFile = nil
                isPlaying = false
                stopDisplayTimer()
                return
            }
            seekFrame = 0
            pausedFrame = nil
            connectGraph(format: file.processingFormat)
            applyNormalization(for: track)      // set the per-track gain before we start
            try startEngineIfNeeded()
            scheduleSegment(from: 0)
            playerNode.play()
            isPlaying = true
            duration = sampleRate > 0 ? Double(audioLengthSamples) / sampleRate : track.duration
            currentTime = 0
            startDisplayTimer()
            updateNowPlayingInfo()
        } catch {
            print("Failed to load \(track.title): \(error)")
            audioFile = nil
            isPlaying = false
            stopDisplayTimer()
        }
    }

    private func scheduleSegment(from startFrame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        let frames = AVAudioFrameCount(max(0, audioLengthSamples - startFrame))
        guard frames > 0 else { return }
        scheduleGeneration &+= 1
        let gen = scheduleGeneration
        playerNode.scheduleSegment(
            file, startingFrame: startFrame, frameCount: frames, at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentCompleted(gen) }
        }
    }

    private func segmentCompleted(_ gen: Int) {
        guard gen == scheduleGeneration else { return }   // stale (seek / next / stop)
        trackDidEnd()
    }

    private func trackDidEnd() {
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            pause()
            return
        }
        switch repeatMode {
        case .one:
            seekFrame = 0
            pausedFrame = nil
            playerNode.stop()
            scheduleSegment(from: 0)
            playerNode.play()
            currentTime = 0
            isPlaying = true
            startDisplayTimer()
            updateNowPlayingInfo()
        case .all, .off:
            advance(auto: true)
        }
    }

    func togglePlayPause() {
        if audioFile == nil {
            if let track = currentTrack {
                play(tracks: queue.isEmpty ? [track] : queue, startAt: currentIndex)
            }
            return
        }
        if isPlaying { pause() } else { resume() }
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
            pause()
            seek(to: 0)
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
        guard audioFile != nil, sampleRate > 0, seconds.isFinite else { return }
        let wasPlaying = isPlaying
        let clamped = max(0, min(seconds, Double(audioLengthSamples) / sampleRate))
        // Never land exactly on the last frame: scheduleSegment(from: length) has
        // 0 frames and no completion fires, which left playback frozen in a
        // "playing" state (e.g. dragging the scrubber fully to the end).
        let target = min(AVAudioFramePosition(clamped * sampleRate), max(0, audioLengthSamples - 1))
        seekFrame = target
        currentTime = Double(target) / sampleRate

        playerNode.stop()                        // clears the schedule; sampleTime resets to 0
        if target < audioLengthSamples {
            scheduleSegment(from: target)
            if wasPlaying {
                pausedFrame = nil
                playerNode.play()
            } else {
                pausedFrame = target
            }
        } else {
            pausedFrame = target
        }
        refreshNowPlayingElapsed()
    }

    private func resume() {
        if audioFile == nil {
            if currentTrack != nil { startCurrent() }
            return
        }
        isSuspended = false
        do {
            activateSession()
            try startEngineIfNeeded()
            if needsReschedule {
                needsReschedule = false
                let frame = pausedFrame ?? currentFrame
                playerNode.stop()
                seekFrame = frame
                scheduleSegment(from: frame)
            }
            pausedFrame = nil
            playerNode.play()
            isPlaying = true
            startDisplayTimer()
            updateNowPlayingInfo()
        } catch {
            print("Resume failed: \(error)")
        }
    }

    private func pause() {
        pausedFrame = currentFrame               // capture the live position first
        playerNode.pause()
        isPlaying = false
        stopDisplayTimer()
        updateCurrentTime()
        updateNowPlayingInfo()
    }

    // MARK: - Shuffle / repeat
    func toggleShuffle() {
        isShuffled.toggle()
        guard let current = currentTrack else { return }
        if isShuffled {
            applyShuffle(keeping: currentIndex)
        } else {
            // Restore the pre-shuffle order — but only if the current track is
            // part of it. If it was queued after play() (Play Next / Add to
            // Queue) it isn't in originalQueue; keep the live queue rather than
            // jump currentIndex to 0 and show a different track than what's
            // actually playing.
            if let idx = originalQueue.firstIndex(of: current) {
                queue = originalQueue
                currentIndex = idx
            }
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
        sleepEndDate = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard let self, !Task.isCancelled else { return }
            self.pause()
            self.sleepTimerMinutes = nil
            self.sleepEndDate = nil
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
        sleepEndDate = nil
        sleepAtTrackEnd = false
    }

    // MARK: - Equalizer
    private func setupEQBands() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.eqCenters[i]
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = false
        }
        eq.globalGain = 0
    }

    func setEQEnabled(_ on: Bool) { eqEnabled = on; applyEQ() }

    func setEQBand(_ index: Int, gain: Float) {
        guard eqGains.indices.contains(index) else { return }
        eqGains[index] = gain
        applyEQ()
    }

    func applyEQPreset(_ gains: [Float]) {
        guard gains.count == eqGains.count else { return }
        eqGains = gains
        eqEnabled = true
        applyEQ()
    }

    private func applyEQ() {
        eq.bypass = !eqEnabled
        for (i, band) in eq.bands.enumerated() where i < eqGains.count {
            band.gain = max(-12, min(12, eqGains[i]))
        }
        saveEQSettings()
    }

    private func saveEQSettings() {
        UserDefaults.standard.set(eqEnabled, forKey: "eq.enabled")
        UserDefaults.standard.set(eqGains.map { Double($0) }, forKey: "eq.gains")
    }

    private func loadEQSettings() {
        eqEnabled = UserDefaults.standard.bool(forKey: "eq.enabled")
        if let g = UserDefaults.standard.array(forKey: "eq.gains") as? [Double], g.count == eqGains.count {
            eqGains = g.map { Float($0) }
        }
        applyEQ()
    }

    // MARK: - Volume normalization
    /// Set the normalization gain for a track. Uses the cached loudness
    /// measurement if we have one; otherwise leaves the gain flat and analyzes in
    /// the background so it's ready next time (avoids a mid-track gain jump).
    private func applyNormalization(for track: Track) {
        if normalizationEnabled, let g = LoudnessService.effectiveGain(for: track) {
            normGain.globalGain = g
        } else {
            normGain.globalGain = 0
        }
        if normalizationEnabled, !LoudnessService.hasMeasurement(for: track) {
            Task { await LoudnessService.analyzeAndCache(track) }
        }
    }

    func setNormalizationEnabled(_ on: Bool) {
        normalizationEnabled = on
        UserDefaults.standard.set(on, forKey: "normalize.enabled")
        // Takes effect from the next track so we never step the gain mid-playback
        // (a sudden globalGain change on a live signal can pop). Warm the cache for
        // the current track so it's normalized as soon as it comes round again.
        if on, let track = currentTrack, !LoudnessService.hasMeasurement(for: track) {
            Task { await LoudnessService.analyzeAndCache(track) }
        }
    }

    private func loadNormalizationSetting() {
        normalizationEnabled = UserDefaults.standard.bool(forKey: "normalize.enabled")
    }

    /// Re-push EQ + normalization gains after the graph is re-wired. A media-
    /// services reset can rebuild the audio units at their defaults, so restore
    /// the levels the current track should be playing at.
    private func reapplyGraphParams() {
        applyEQ()
        if let track = currentTrack { applyNormalization(for: track) }
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
