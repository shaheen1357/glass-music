import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Observation

enum RepeatMode: String {
    case off, all, one
}

@MainActor
@Observable
final class PlayerEngine {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying = false
    /// Fetching a server song before it can start: the play button shows a spinner.
    private(set) var isLoading = false
    /// Why the last song couldn't start, shown under the controls; nil when fine.
    private(set) var loadError: String?
    var currentTime: Double = 0
    var duration: Double = 0
    var repeatMode: RepeatMode = .off
    var isShuffled = false
    var sleepTimerMinutes: Int? = nil
    private(set) var sleepEndDate: Date? = nil    // for a live countdown in the UI
    var sleepAtTrackEnd = false

    // MARK: Track transitions (user-facing)
    private(set) var gaplessEnabled = true         // remove the silence between tracks
    private(set) var crossfadeDuration: Double = 0 // seconds (0...12); 0 = off
    private(set) var autoplayEnabled = true        // keep playing similar songs when the queue ends

    /// Supplies more tracks to continue with when the queue runs out (autoplay /
    /// radio). Given the last track + the ids already queued, returns fresh tracks.
    var onNeedMore: ((Track, Set<String>) -> [Track])?

    // MARK: Audio engine graph
    // Two player chains feed a shared submixer so one track can hand off into the
    // next without tearing down the graph (crossfade + gapless):
    //     playerA -> normA -\
    //                        +-> subMixer -> eq -> mainMixer -> output
    //     playerB -> normB -/
    // Exactly one chain is "active" at a time: it owns the queue position and the
    // render clock. The other chain is idle except during a brief transition.
    private let engine = AVAudioEngine()
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    // Per-track normalization gain. A 0-band EQ is just a globalGain node that can
    // boost as well as attenuate (a player node's volume can't exceed 1.0).
    private let normA = AVAudioUnitEQ(numberOfBands: 0)
    private let normB = AVAudioUnitEQ(numberOfBands: 0)
    private let subMixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private var currentFormat: AVAudioFormat?   // active track's file format
    private var graphFormat: AVAudioFormat?     // fixed subMixer -> eq -> mainMixer format

    // Active-chain indirection. All the existing single-node logic (seek, pause,
    // resume, the render clock) keeps working unchanged by talking to `playerNode`.
    private var activeIsA = true
    private var playerNode: AVAudioPlayerNode { activeIsA ? playerA : playerB }
    private var idleNode:   AVAudioPlayerNode { activeIsA ? playerB : playerA }
    private var activeNorm: AVAudioUnitEQ { activeIsA ? normA : normB }
    private var idleNorm:   AVAudioUnitEQ { activeIsA ? normB : normA }

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
    private var isTransitioning = false                     // a gapless/crossfade hand-off is in flight
    private var fadeTask: Task<Void, Never>?               // drives the volume ramp / commit
    private var incomingGen = 0                            // completion token for the incoming chain
    private var pendingIncomingFile: AVAudioFile?          // the incoming track, awaiting commit
    private var pendingNext: Track?

    private var originalQueue: [Track] = []
    private var sleepTask: Task<Void, Never>?
    var onPlay: ((Track) -> Void)?

    /// Resolve a track to a local file to play: a local track returns as-is, a
    /// remote one is downloaded to the cache first. Set by the app; nil = local-only.
    var ensureLocalURL: ((Track) async -> URL?)?
    private var startToken = 0                             // guards async remote-start races

    // MARK: Streaming (hybrid)
    // A server song that isn't on the phone yet plays through AVPlayer, which starts
    // within seconds while the file is still arriving. The engine above needs whole
    // files, so a streamed song plays without EQ, levelling, crossfade or gapless.
    // Once the stream is fully buffered the whole file is fetched into the cache (on
    // Wi-Fi), and every later play of that song goes through the engine with all of it.
    /// The song's file if it's already on the phone (downloaded or cached). Instant.
    var readyFileFor: ((Track) -> URL?)?
    /// Where to stream a server song from; nil when it can't be streamed (offline).
    var streamURLFor: ((Track) -> URL?)?
    /// Fetch a streamed song's whole file into the cache, for the engine next time.
    var fillCache: ((Track) -> Void)?
    /// True while the current song is streaming (no EQ / levelling / crossfade).
    private(set) var isStreaming = false
    /// A radio station is playing: live, no length, no seeking.
    private(set) var isLive = false
    /// The song a station says it's playing right now, when it says.
    private(set) var liveTitle: String?
    /// What's actually playing, as a short tag for the player: "FLAC", "MP3 320",
    /// "AAC 128"... nil when unknown.
    private(set) var nowFormat: String?
    /// The tag for a streamed server song ("MP3 320"); set by the app.
    var streamFormatFor: ((Track) -> String?)?
    /// True when there's no way to reach the server (no connection, or Offline Mode).
    var isOfflineNow: (() -> Bool)?
    @ObservationIgnored private var metadataReader: StreamMetadataReader?
    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var streamObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var streamTimeObserver: Any?
    @ObservationIgnored private var streamEndObserver: NSObjectProtocol?
    @ObservationIgnored private var streamCacheFilled = false
    /// A converted stream can't jump to a byte, so a seek restarts it from a time
    /// (Navidrome's timeOffset). The stream's own clock then counts from that point.
    @ObservationIgnored private var streamBaseURL: URL?
    @ObservationIgnored private var streamTrack: Track?
    @ObservationIgnored private var streamOffset: Double = 0

    // MARK: Session persistence (last song + position + shuffle/repeat + queue)
    private struct PersistedState: Codable {
        var queueIDs: [String]
        var originalQueueIDs: [String]
        var currentIndex: Int
        var currentTime: Double
        var isShuffled: Bool
        var repeatMode: String
    }
    private let stateURL: URL = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("playbackstate.json")
    }()

    var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var upNext: [Track] {
        guard currentIndex + 1 < queue.count else { return [] }
        return Array(queue[(currentIndex + 1)...])
    }

    init() {
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(normA)
        engine.attach(normB)
        engine.attach(subMixer)
        engine.attach(eq)
        setupEQBands()
        loadEQSettings()
        loadNormalizationSetting()
        loadTransitionSettings()
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

    /// Canonical format for the shared tail (subMixer -> eq -> mainMixer). The
    /// submixer sample-rate-converts each track's native input to this, so two
    /// tracks of different rates can overlap during a crossfade. iPhone output runs
    /// at the session rate (typically 48 kHz), so this matches what the old
    /// single-node graph fed the hardware — no extra quality loss.
    private func canonicalFormat() -> AVAudioFormat {
        let sr = AVAudioSession.sharedInstance().sampleRate
        return AVAudioFormat(standardFormatWithSampleRate: sr > 0 ? sr : 48_000, channels: 2)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    /// Wire the fixed tail. It never carries a specific track, so it can stay put
    /// across track changes.
    private func wireFixedChain() {
        let fmt = canonicalFormat()
        graphFormat = fmt
        engine.connect(subMixer, to: eq, format: fmt)
        engine.connect(eq, to: engine.mainMixerNode, format: fmt)
    }

    /// Wire one player chain (node -> norm -> subMixer) at a file's native format.
    /// The node must be stopped.
    private func connectInput(_ node: AVAudioPlayerNode, _ norm: AVAudioUnitEQ, format: AVAudioFormat) {
        engine.connect(node, to: norm, format: format)
        engine.connect(norm, to: subMixer, format: format)
    }

    /// Prepare the graph to play the active track's file. The active node must be
    /// stopped before calling this.
    private func connectGraph(format: AVAudioFormat) {
        if graphFormat == nil { wireFixedChain() }
        currentFormat = format
        connectInput(playerNode, activeNorm, format: format)
    }

    /// Re-establish the whole graph after a route / media-services change.
    private func rewire() {
        wireFixedChain()
        if let f = currentFormat { connectInput(playerNode, activeNorm, format: f) }
    }

    // MARK: - Interruption / route / config handling
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        abortTransition()
        switch type {
        case .began:
            isSuspended = true                 // Core Audio already stopped the engine
            // The render clock is gone, so capturing currentFrame here would read
            // ~0 and rewind the song. Use the last published position instead —
            // this is the Instagram-Reel / call "restarts from the top" fix.
            pausedFrame = capturedPlayhead()
            isPlaying = false
            stopDisplayTimer()
            updateNowPlayingInfo()
        case .ended:
            // Do NOT auto-resume, even when iOS sends .shouldResume. After a call /
            // reel / other app grabs audio, playback stays paused until the user
            // presses play. needsReschedule makes that manual resume pick up from
            // where it stopped (the render clock is gone after an interruption).
            isSuspended = false
            needsReschedule = true
            updateNowPlayingInfo()
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
        abortTransition()
        activateSession()
        pausedFrame = capturedPlayhead()
        isPlaying = false
        stopDisplayTimer()
        rewire()
        reapplyGraphParams()
        needsReschedule = true
        updateNowPlayingInfo()
    }

    private func restartAndResume() {
        abortTransition()
        guard audioFile != nil, sampleRate > 0 else { return }
        // currentTime is the last position the timer published; the render clock
        // may already be gone by the time a config-change notification arrives.
        let resumeFrame = min(max(0, AVAudioFramePosition(max(0, currentTime) * sampleRate)), audioLengthSamples)
        do {
            activateSession()
            rewire()
            reapplyGraphParams()
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

    /// Best-known playhead when the render clock can't be trusted — an interruption
    /// or media reset has already stopped the engine, so `currentFrame` may read the
    /// start of the schedule (~0). Take whichever is larger of the live clock and
    /// the last position the display timer published (currentTime).
    private func capturedPlayhead() -> AVAudioFramePosition {
        let byClock = currentFrame
        let byTime = AVAudioFramePosition(max(0, currentTime) * sampleRate)
        return min(max(byClock, byTime), audioLengthSamples)
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
        maybeBeginTransition()
        // Don't rewrite Now Playing elapsed/rate every tick — the system
        // extrapolates position between discrete writes, and per-tick writes get
        // throttled and desync the lock screen in long background sessions. We set
        // elapsed on discrete events only (play / pause / seek / track change).
    }

    // MARK: - Playback control
    func play(tracks: [Track], startAt index: Int) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        abortTransition()
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

    /// Shuffle these tracks. If the song currently playing is part of them,
    /// shuffle the queue AROUND it — keep it playing — instead of discarding it
    /// and jumping to a new random track. Only a genuinely new context starts
    /// fresh from a random track.
    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        abortTransition()
        isShuffled = true
        // Never interrupt: if a song is playing, keep it and queue the shuffled
        // playlist to follow it. Only start fresh when nothing is playing.
        if audioFile != nil || streamPlayer != nil, let current = currentTrack {
            var rest = tracks.filter { $0.id != current.id }
            rest.shuffle()
            originalQueue = tracks
            queue = [current] + rest
            currentIndex = 0
            updateNowPlayingInfo()
        } else {
            play(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
        }
    }

    private func startCurrent() {
        guard let track = currentTrack else { return }
        startToken &+= 1
        let token = startToken
        // Fast path — the file is already on disk (every local track, and any cached
        // remote one): run synchronously, exactly as before, no behaviour change.
        loadError = nil
        tearDownStream()
        // A radio station: always live through the streaming player.
        if track.isRadio {
            startStream(track, url: track.url, token: token)
            return
        }
        // On the phone (your file, or a server song downloaded or cached): the engine, now.
        if let ready = playableFile(track) {
            isLoading = false
            startCurrentResolved(track, url: ready)
            return
        }
        // Offline and only on the server: skip ahead to the next song that can play,
        // the way a greyed-out song is passed over, rather than stalling on it.
        if isOfflineNow?() == true {
            skipToPlayable(after: currentIndex)
            return
        }
        // Not on the phone: stream it, starting in seconds.
        if SubsonicID.isRemote(track), let url = streamURLFor?(track) {
            startStream(track, url: url, token: token)
            return
        }
        fetchThenPlay(track, token: token)
    }

    /// Offline: from the queue position after `index`, play the first song that's on
    /// the phone. If none is, stop and say why.
    private func skipToPlayable(after index: Int) {
        guard !queue.isEmpty else { return }
        for step in 1...queue.count {
            let i = index + step
            guard i < queue.count || repeatMode == .all else { break }
            let j = i % queue.count
            if j == index { break }
            let t = queue[j]
            if !t.isRadio && playableFile(t) != nil {
                currentIndex = j
                startCurrent()
                return
            }
        }
        isLoading = false
        isPlaying = false
        stopDisplayTimer()
        loadError = "You're offline, and nothing else in this queue is on the phone."
        updateNowPlayingInfo()
    }

    /// The whole-file path: fetch the song, then hand it to the engine — unless a newer
    /// request (next / previous / stop) superseded this one meanwhile. Used when
    /// streaming isn't possible, and as the fallback when a stream fails to open.
    private func fetchThenPlay(_ track: Track, token: Int) {
        isPlaying = false
        isLoading = true
        stopDisplayTimer()
        updateNowPlayingInfo()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let url = await self.ensureLocalURL?(track)
            guard token == self.startToken, self.currentTrack?.id == track.id else { return }
            self.isLoading = false
            guard let url else {
                self.loadError = "Couldn't get “\(track.title)” from the server."
                return
            }
            self.startCurrentResolved(track, url: url)
        }
    }

    private func startCurrentResolved(_ track: Track, url: URL) {
        tearDownStream()
        nowFormat = FormatTag.forFile(url, duration: track.duration)
        onPlay?(track)
        isSuspended = false
        needsReschedule = false
        idleNode.stop()                         // clear any leftover transition node
        idleNode.volume = 1
        playerNode.volume = 1
        playerNode.stop()                       // fires a stale completion...
        scheduleGeneration &+= 1                // ...neutralize it even if the load below fails

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            sampleRate = file.processingFormat.sampleRate
            audioLengthSamples = file.length
            // #3: a zero-length/degenerate file would "play" forever (no completion) — bail.
            guard audioLengthSamples > 0 else {
                audioFile = nil
                isPlaying = false
                stopDisplayTimer()
                discardBrokenCopy(of: track, at: url)
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
            savePlaybackState()
            prefetchUpcoming()
        } catch {
            print("Failed to load \(track.title): \(error)")
            audioFile = nil
            isPlaying = false
            stopDisplayTimer()
            discardBrokenCopy(of: track, at: url)
        }
    }

    /// A server song's file that won't open is thrown away, so the next play fetches a
    /// good copy instead of failing on the same bad one forever. A broken download is
    /// re-queued by the sync on its next pass. Your own files are never touched.
    private func discardBrokenCopy(of track: Track, at url: URL) {
        loadError = "Couldn't play “\(track.title)”. Try again to fetch a fresh copy."
        guard SubsonicID.isRemote(track) else { return }
        let cacheURL = SubsonicCache.dir.appendingPathComponent(url.lastPathComponent)
        if url.path.hasPrefix(SubsonicCache.downloadsDir.path) || SubsonicCache.isLink(url) {
            SubsonicCache.removeDownload(cacheURL)      // the sync re-queues it
        } else if url.path.hasPrefix(SubsonicCache.dir.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The real file to open for a track, or nil if it isn't on the phone. Your own
    /// songs: their file. Server songs: asked of the sync, which answers with the
    /// download itself (not the cache link to it) or the cached copy, under this
    /// launch's container — never the path stored with the track.
    private func playableFile(_ track: Track) -> URL? {
        if SubsonicID.isRemote(track) { return readyFileFor?(track) }
        return FileManager.default.fileExists(atPath: track.url.path) ? track.url : nil
    }

    /// Warm the cache for the next track so a gapless/crossfade hand-off (which
    /// opens the file synchronously) finds it on disk. No-op for local tracks.
    private func prefetchUpcoming() {
        guard let hook = ensureLocalURL, let next = upcomingTrack(),
              playableFile(next) == nil else { return }
        Task { _ = await hook(next) }
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
        if isTransitioning {
            // During a hand-off, scheduleGeneration still belongs to the OUTGOING
            // node; its completion firing means the outgoing track truly ended, so
            // commit now (covers the case where its end beats the fadeTask timer).
            // The incoming node's own token differs, so it's ignored here.
            if gen == scheduleGeneration { commitPendingTransition() }
            return
        }
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
            if streamPlayer != nil, let track = streamTrack, let base = streamBaseURL {
                startStream(track, url: base, token: startToken, offset: 0, announce: false)
                return
            }
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
        if streamPlayer != nil {
            if isPlaying { pause() } else { resume() }
            return
        }
        if audioFile == nil {
            if let track = currentTrack {
                play(tracks: queue.isEmpty ? [track] : queue, startAt: currentIndex)
            }
            return
        }
        if isPlaying { pause() } else { resume() }
    }

    func next() { abortTransition(); advance(auto: false) }

    private func advance(auto: Bool) {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            startCurrent()
        } else if repeatMode == .all {
            currentIndex = 0
            startCurrent()
        } else if autoplayEnabled, let last = currentTrack,
                  let more = onNeedMore?(last, Set(queue.map(\.id))), !more.isEmpty {
            // Queue exhausted → keep the music going with similar songs (radio).
            queue.append(contentsOf: more)
            currentIndex += 1
            startCurrent()
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        abortTransition()
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
        if isLive { return }                     // a live station has nowhere to seek to
        if streamPlayer != nil, let track = streamTrack, let base = streamBaseURL {
            guard seconds.isFinite else { return }
            let target = max(0, min(seconds, max(0, duration - 1)))
            let wasPlaying = isPlaying
            // Restart the converted stream from the new time; it starts in a fraction
            // of a second (no byte ranges to seek within).
            startStream(track, url: base, token: startToken, offset: target, announce: false)
            if !wasPlaying {
                streamPlayer?.pause()
                isPlaying = false
                isLoading = false
            }
            refreshNowPlayingElapsed()
            return
        }
        guard audioFile != nil, sampleRate > 0, seconds.isFinite else { return }
        abortTransition()
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
        abortTransition()
        if let p = streamPlayer {
            activateSession()
            p.play()
            isPlaying = true
            updateNowPlayingInfo()
            return
        }
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
        abortTransition()
        if let p = streamPlayer {
            p.pause()
            isPlaying = false
            updateNowPlayingInfo()
            savePlaybackState()
            return
        }
        pausedFrame = currentFrame               // capture the live position first
        playerNode.pause()
        isPlaying = false
        stopDisplayTimer()
        updateCurrentTime()
        updateNowPlayingInfo()
        savePlaybackState()
    }

    // MARK: - Streaming
    private func startStream(_ track: Track, url: URL, token: Int,
                             offset: Double = 0, announce: Bool = true) {
        tearDownStream()
        // Silence the engine: the stream takes over this song.
        abortTransition()
        idleNode.stop()
        playerNode.stop()
        scheduleGeneration &+= 1                 // neutralise the engine's stale completion
        audioFile = nil
        pausedFrame = nil
        stopDisplayTimer()
        activateSession()

        var itemURL = url
        if offset >= 1, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "timeOffset", value: String(Int(offset)))]
            itemURL = c.url ?? url
        }
        streamBaseURL = url
        streamTrack = track
        streamOffset = offset >= 1 ? Double(Int(offset)) : 0
        let item = AVPlayerItem(url: itemURL)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        streamPlayer = p
        isStreaming = true
        isLive = track.isRadio
        liveTitle = nil
        nowFormat = track.isRadio ? (track.album == "Radio" ? "LIVE" : "LIVE · " + track.album)
                                  : streamFormatFor?(track)
        if track.isRadio {
            // Stations send the current song as stream metadata (ICY StreamTitle).
            let reader = StreamMetadataReader { [weak self] title in
                guard let self, token == self.startToken else { return }
                self.liveTitle = title
                self.updateNowPlayingInfo()
            }
            let output = AVPlayerItemMetadataOutput(identifiers: nil)
            output.setDelegate(reader, queue: .main)
            item.add(output)
            metadataReader = reader
        }
        streamCacheFilled = false
        isLoading = true                         // until audio actually flows
        isPlaying = false
        duration = track.duration
        currentTime = streamOffset

        streamObservations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.streamStatusChanged(item, track: track, token: token) }
            },
            p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                Task { @MainActor in self?.streamTimeControlChanged(p, token: token) }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.streamBuffered(item, track: track, token: token) }
            },
        ]
        streamTimeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, token == self.startToken, t.seconds.isFinite else { return }
                self.currentTime = self.streamOffset + t.seconds
            }
        }
        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.startToken else { return }
                self.trackDidEnd()
            }
        }
        if announce { onPlay?(track) }
        p.play()
        updateNowPlayingInfo()
        savePlaybackState()
    }

    private func streamStatusChanged(_ item: AVPlayerItem, track: Track, token: Int) {
        guard token == startToken else { return }
        switch item.status {
        case .readyToPlay:
            // A converted stream reports no length (or only the rest after an offset):
            // keep the song's own duration then.
            let d = item.duration.seconds
            if streamOffset == 0, d.isFinite, d > 0 { duration = d; updateNowPlayingInfo() }
        case .failed:
            // The stream wouldn't open (format, network, server): fall back to fetching
            // the whole file and playing it through the engine, as before.
            print("Stream failed for \(track.title): \(String(describing: item.error))")
            tearDownStream()
            fetchThenPlay(track, token: token)
        default:
            break
        }
    }

    private func streamTimeControlChanged(_ p: AVPlayer, token: Int) {
        guard token == startToken, p === streamPlayer else { return }
        switch p.timeControlStatus {
        case .playing:
            isLoading = false
            isPlaying = true
        case .waitingToPlayAtSpecifiedRate:
            isLoading = true                     // buffering: the spinner, not a dead button
        case .paused:
            isLoading = false
            isPlaying = false
        @unknown default:
            break
        }
        updateNowPlayingInfo()
    }

    /// Once the whole song has arrived for the stream, fetch its file into the cache
    /// (so the next play uses the engine) and warm the next song. Not before: on a slow
    /// connection that would starve the stream you're listening to.
    private func streamBuffered(_ item: AVPlayerItem, track: Track, token: Int) {
        guard token == startToken, !streamCacheFilled else { return }
        guard duration > 0 else { return }
        let end = item.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0
        guard streamOffset + end >= duration - 1 else { return }
        streamCacheFilled = true
        fillCache?(track)                        // the sync decides (only for Original)
    }

    private func tearDownStream() {
        guard let p = streamPlayer else { return }
        p.pause()
        if let o = streamTimeObserver { p.removeTimeObserver(o) }
        streamTimeObserver = nil
        if let e = streamEndObserver { NotificationCenter.default.removeObserver(e) }
        streamEndObserver = nil
        streamObservations.forEach { $0.invalidate() }
        streamObservations = []
        p.replaceCurrentItem(with: nil)
        streamPlayer = nil
        isStreaming = false
        isLive = false
        liveTitle = nil
        metadataReader = nil
    }

    // MARK: - Track transitions (gapless / crossfade)
    func setGaplessEnabled(_ on: Bool) {
        gaplessEnabled = on
        UserDefaults.standard.set(on, forKey: "transition.gapless")
    }

    func setCrossfadeDuration(_ seconds: Double) {
        crossfadeDuration = max(0, min(12, seconds))
        UserDefaults.standard.set(crossfadeDuration, forKey: "transition.crossfade")
    }

    func setAutoplayEnabled(_ on: Bool) {
        autoplayEnabled = on
        UserDefaults.standard.set(on, forKey: "autoplay.enabled")
    }

    private func loadTransitionSettings() {
        let d = UserDefaults.standard
        gaplessEnabled = d.object(forKey: "transition.gapless") == nil ? true : d.bool(forKey: "transition.gapless")
        crossfadeDuration = min(12, max(0, d.double(forKey: "transition.crossfade")))
        autoplayEnabled = d.object(forKey: "autoplay.enabled") == nil ? true : d.bool(forKey: "autoplay.enabled")
    }

    /// The track that will play after the current one (honours repeat-all wrap).
    private func upcomingIndex() -> Int? {
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }
    private func upcomingTrack() -> Track? {
        guard let i = upcomingIndex() else { return nil }
        return queue[i]
    }

    /// Called from the display clock as the active track nears its end. Starts the
    /// next track on the idle chain — overlapping (crossfade) or scheduled exactly
    /// at the boundary (gapless) — without tearing down the active chain.
    private func maybeBeginTransition() {
        guard !isTransitioning, isPlaying, audioFile != nil, sampleRate > 0 else { return }
        guard repeatMode != .one else { return }          // repeat-one loops in place
        guard let next = upcomingTrack() else { return }   // nothing to hand off to
        let remaining = duration - currentTime
        guard remaining.isFinite else { return }
        if crossfadeDuration > 0 {
            if remaining <= crossfadeDuration && remaining > 0.05 {
                beginTransition(to: next, fade: crossfadeDuration)
            }
        } else if gaplessEnabled {
            // Arm well ahead of the boundary: the incoming track is scheduled to
            // start at an exact host time, so arming early costs nothing and gives
            // the (coalesced-in-background) timer plenty of slack to catch it.
            if remaining <= 2.0 && remaining > 0.05 {
                beginTransition(to: next, fade: 0)
            }
        }
    }

    private func beginTransition(to next: Track, fade: Double) {
        guard let renderTime = playerNode.lastRenderTime, playerNode.isPlaying else { return }
        // Only hand off to a track whose file is already on disk; otherwise let the
        // plain end-of-track path advance (which downloads it) — a tiny gap at worst.
        guard let nextURL = playableFile(next) else { return }
        // Gapless needs a valid host clock for a sample-accurate join; without it,
        // do nothing and let the plain end-of-track path advance (a tiny gap). We
        // haven't touched any state yet, so the active node's completion is intact.
        if fade == 0 && !renderTime.isHostTimeValid { return }

        let incoming: AVAudioFile
        do { incoming = try AVAudioFile(forReading: nextURL) }
        catch { print("Transition load failed: \(error)"); return }
        guard incoming.length > 0 else { return }

        // Playhead from the SAME render snapshot that seeds the gapless start time,
        // so the scheduled join lands exactly on the outgoing track's last sample
        // (mixing two snapshots could leave a sub-ms overlap/click at the seam).
        let rendered = playerNode.playerTime(forNodeTime: renderTime)?.sampleTime ?? 0
        let playhead = max(0, min(seekFrame + rendered, audioLengthSamples))
        let framesRemaining = max(0, audioLengthSamples - playhead)
        let secondsRemaining = Double(framesRemaining) / sampleRate
        guard secondsRemaining > 0.02 else { return }

        isTransitioning = true

        // Prepare the idle chain for the incoming track.
        idleNode.stop()
        idleNode.volume = fade > 0 ? 0 : 1
        connectInput(idleNode, idleNorm, format: incoming.processingFormat)
        idleNorm.globalGain = normalizationGain(for: next)
        if normalizationEnabled, !LoudnessService.hasMeasurement(for: next) {
            Task { await LoudnessService.analyzeAndCache(next) }
        }

        // Give the incoming chain its OWN completion token, leaving the active
        // node's token untouched. That way the active node's own end-of-data
        // completion stays valid (harmlessly ignored while isTransitioning is set,
        // and it correctly resumes duty if the hand-off is aborted). The token is
        // promoted to scheduleGeneration at commit.
        let gen = scheduleGeneration &+ 1
        incomingGen = gen
        pendingIncomingFile = incoming
        pendingNext = next
        idleNode.scheduleSegment(
            incoming, startingFrame: 0, frameCount: AVAudioFrameCount(incoming.length),
            at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.segmentCompleted(gen) }
        }

        if fade > 0 {
            idleNode.play()                                   // overlap now, ramp below
            runTransition(fade: min(fade, secondsRemaining), commitAfter: min(fade, secondsRemaining), gen: gen)
        } else {
            // Start the incoming track exactly when the active one ends: sample-
            // accurate, no gap, no overlap.
            let startHost = renderTime.hostTime &+ AVAudioTime.hostTime(forSeconds: secondsRemaining)
            idleNode.play(at: AVAudioTime(hostTime: startHost))
            runTransition(fade: 0, commitAfter: secondsRemaining, gen: gen)
        }
    }

    /// Ramp the crossfade (equal-power) if any, then hand over. The AUDIO seam is
    /// already exact (scheduled `at:` for gapless, the overlap for crossfade) — the
    /// commit only moves the bookkeeping/UI over.
    private func runTransition(fade: Double, commitAfter: Double, gen: Int) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if fade > 0 {
                let steps = max(1, Int(fade / 0.02))
                for i in 1...steps {
                    if Task.isCancelled { return }
                    let t = Double(i) / Double(steps)
                    self.playerNode.volume = Float(cos(t * .pi / 2))   // active == outgoing here
                    self.idleNode.volume = Float(sin(t * .pi / 2))     // idle == incoming here
                    try? await Task.sleep(for: .seconds(0.02))
                }
            } else {
                try? await Task.sleep(for: .seconds(max(0, commitAfter)))
            }
            if Task.isCancelled { return }
            guard gen == self.incomingGen else { return }
            self.commitPendingTransition()
        }
    }

    /// Commit the armed hand-off. Driven by whichever fires first: the fadeTask
    /// timer, or the outgoing node reaching its real end of data (see
    /// segmentCompleted). Idempotent — the loser is a no-op.
    private func commitPendingTransition() {
        guard isTransitioning, let file = pendingIncomingFile, let next = pendingNext else { return }
        commitTransition(incomingFile: file, next: next)
    }

    /// Hand over: the incoming chain becomes active and keeps playing uninterrupted.
    private func commitTransition(incomingFile: AVAudioFile, next: Track) {
        guard isTransitioning else { return }
        // Stop the ramp FIRST. When the outgoing node's natural end drives the
        // commit (beating the fadeTask timer), the ramp is still suspended at its
        // await; without this cancel it would resume after the activeIsA flip and
        // ramp the NEW active track's volume down to silence.
        fadeTask?.cancel()
        let outgoing = playerNode
        outgoing.stop()
        outgoing.volume = 1

        activeIsA.toggle()                 // the incoming chain is now active
        playerNode.volume = 1
        idleNode.volume = 1                // (idleNode is now the outgoing chain) tidy
        scheduleGeneration = incomingGen   // its completion now governs the next end

        if let i = upcomingIndex() { currentIndex = i }
        audioFile = incomingFile
        currentFormat = incomingFile.processingFormat
        sampleRate = incomingFile.processingFormat.sampleRate
        audioLengthSamples = incomingFile.length
        seekFrame = 0
        pausedFrame = nil
        duration = sampleRate > 0 ? Double(audioLengthSamples) / sampleRate : next.duration
        // Crossfade: the incoming track has already been sounding for `fade`
        // seconds, so read its true playhead rather than snapping to 0. Gapless:
        // it just started, so this is ~0.
        currentTime = sampleRate > 0 ? Double(currentFrame) / sampleRate : 0
        isTransitioning = false
        fadeTask = nil
        pendingIncomingFile = nil
        pendingNext = nil
        isSuspended = false
        needsReschedule = false
        onPlay?(next)
        updateNowPlayingInfo()
    }

    /// Collapse any in-flight transition back to the single active (outgoing) track.
    /// The UI shows the outgoing track until commit, so reverting to it is seamless.
    /// Every control that assumes one active node calls this first.
    private func abortTransition() {
        guard isTransitioning else { return }
        fadeTask?.cancel()
        fadeTask = nil
        isTransitioning = false
        pendingIncomingFile = nil
        pendingNext = nil
        idleNode.stop()
        idleNode.volume = 1
        playerNode.volume = 1
        // The active node kept its original schedule and completion token, so it
        // still advances correctly on its own when it reaches the end — nothing to
        // reschedule here.
    }

    // MARK: - Shuffle / repeat
    func toggleShuffle() {
        abortTransition()
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
        savePlaybackState()
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
        abortTransition()
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        savePlaybackState()
    }

    // MARK: - Queue editing
    func addToQueue(_ track: Track) {
        if queue.isEmpty { play(tracks: [track], startAt: 0) }
        else { queue.append(track); updateNowPlayingInfo() }
    }

    func playNext(_ track: Track) {
        abortTransition()   // the armed "next" would otherwise be wrong
        if queue.isEmpty { play(tracks: [track], startAt: 0) }
        else { queue.insert(track, at: min(currentIndex + 1, queue.count)) }
    }

    func removeFromUpNext(at offsets: IndexSet) {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        abortTransition()
        var up = upNext
        up.remove(atOffsets: offsets)
        queue = Array(queue[0...currentIndex]) + up
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        abortTransition()
        var up = upNext
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[0...currentIndex]) + up
    }

    func clearUpNext() {
        guard !queue.isEmpty, currentIndex < queue.count else { return }
        abortTransition()
        queue = Array(queue[0...currentIndex])
    }

    func jump(to track: Track) {
        guard let idx = queue.firstIndex(of: track) else { return }
        abortTransition()
        currentIndex = idx
        startCurrent()
    }

    // MARK: - Session persistence
    /// Snapshot the current session (last song + position + shuffle/repeat + queue)
    /// so it can be restored on the next launch.
    private func savePlaybackState() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let state = PersistedState(
            queueIDs: queue.map(\.id),
            originalQueueIDs: originalQueue.map(\.id),
            currentIndex: currentIndex,
            currentTime: max(0, currentTime),
            isShuffled: isShuffled,
            repeatMode: repeatMode.rawValue
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Called when the app goes to the background: refresh the playhead from the
    /// live clock, then persist — this is what captures the position when you leave
    /// for Instagram and the app is later killed.
    func persistNow() {
        if sampleRate > 0 { currentTime = Double(currentFrame) / sampleRate }
        savePlaybackState()
    }

    /// Restore the last session on launch: rebuild the queue from the library, set
    /// shuffle/repeat, and load the last song PAUSED at its saved position (so the
    /// mini-player is there and ready, without blasting audio on open). No-op if a
    /// session is already active or nothing was saved.
    func restorePlaybackState(using library: LibraryStore) {
        guard queue.isEmpty else { return }
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        let resolved = s.queueIDs.compactMap { library.tracksByID[$0] }
        guard !resolved.isEmpty else { return }
        let currentID = s.queueIDs.indices.contains(s.currentIndex) ? s.queueIDs[s.currentIndex] : nil
        queue = resolved
        originalQueue = s.originalQueueIDs.compactMap { library.tracksByID[$0] }
        isShuffled = s.isShuffled
        repeatMode = RepeatMode(rawValue: s.repeatMode) ?? .off
        if let id = currentID, let idx = resolved.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
        } else {
            currentIndex = min(max(0, s.currentIndex), resolved.count - 1)
        }
        loadCurrentPaused(at: s.currentTime)
    }

    /// Load the current track into the graph WITHOUT playing, positioned at
    /// `seconds`. resume() (or a play tap) picks up from here via needsReschedule.
    private func loadCurrentPaused(at seconds: Double) {
        guard let track = currentTrack else { return }
        // Remote track not cached yet: show it as current (paused) without loading
        // the engine; a play tap routes through startCurrent, which fetches it.
        guard let fileURL = playableFile(track) else {
            audioFile = nil
            duration = track.duration
            currentTime = min(max(0, seconds), track.duration)
            isPlaying = false
            updateNowPlayingInfo()
            return
        }
        idleNode.stop(); idleNode.volume = 1; playerNode.volume = 1
        playerNode.stop()
        scheduleGeneration &+= 1
        do {
            let file = try AVAudioFile(forReading: fileURL)
            nowFormat = FormatTag.forFile(fileURL, duration: track.duration)
            audioFile = file
            sampleRate = file.processingFormat.sampleRate
            audioLengthSamples = file.length
            guard audioLengthSamples > 0 else { audioFile = nil; return }
            duration = Double(audioLengthSamples) / sampleRate
            let target = min(max(0, AVAudioFramePosition(max(0, seconds) * sampleRate)), max(0, audioLengthSamples - 1))
            seekFrame = target
            pausedFrame = target
            currentTime = Double(target) / sampleRate
            connectGraph(format: file.processingFormat)
            applyNormalization(for: track)
            needsReschedule = true            // resume() schedules from pausedFrame, then plays
            isSuspended = false
            isPlaying = false
            updateNowPlayingInfo()
        } catch {
            print("Restore load failed: \(error)")
            audioFile = nil
        }
    }

    // MARK: - Sleep timer
    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerMinutes = minutes
        sleepEndDate = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { @MainActor [weak self] in
            let total = Double(minutes) * 60
            let fade = 8.0
            try? await Task.sleep(for: .seconds(max(0, total - fade)))
            guard let self, !Task.isCancelled else { return }
            // Ease the volume down over the last few seconds instead of a hard cut.
            // Capture the node once so a track-skip mid-fade doesn't duck the new one.
            let node = self.playerNode
            let steps = 40
            for i in 1...steps {
                if Task.isCancelled { node.volume = 1; return }
                node.volume = Float(max(0, 1 - Double(i) / Double(steps)))
                try? await Task.sleep(for: .seconds(fade / Double(steps)))
            }
            if Task.isCancelled { node.volume = 1; return }
            self.pause()
            node.volume = 1                     // restore for the next play
            self.playerNode.volume = 1
            self.sleepTimerMinutes = nil
            self.sleepEndDate = nil
            self.sleepTask = nil
        }
    }

    func sleepAtEndOfTrack() {
        // Cancel any hand-off so the current track really is the last one to play.
        abortTransition()
        cancelSleepTimer()
        sleepAtTrackEnd = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerMinutes = nil
        sleepEndDate = nil
        sleepAtTrackEnd = false
        playerNode.volume = 1   // undo any in-progress sleep fade
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
    private func normalizationGain(for track: Track) -> Float {
        guard normalizationEnabled, let g = LoudnessService.effectiveGain(for: track) else { return 0 }
        return g
    }

    private func applyNormalization(for track: Track) {
        activeNorm.globalGain = normalizationGain(for: track)
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
            MPMediaItemPropertyTitle: liveTitle ?? track.title,
            MPMediaItemPropertyArtist: liveTitle == nil ? track.artist : track.title,
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

/// Hands a station's "now playing" text (ICY StreamTitle, or a title tag) to a closure.
final class StreamMetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onTitle: @MainActor (String) -> Void
    init(onTitle: @escaping @MainActor (String) -> Void) { self.onTitle = onTitle }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        let items = groups.flatMap(\.items)
        let item = items.first { $0.identifier == .icyMetadataStreamTitle }
            ?? items.first { $0.commonKey == .commonKeyTitle }
        guard let title = item?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return }
        MainActor.assumeIsolated { onTitle(title) }
    }
}

/// The short format tag shown in the player and the song menu.
enum FormatTag {
    /// From the file itself: its type, and for lossy files the bitrate worked out
    /// from size and length, snapped to the usual steps (320, 256, 192, 160, 128).
    static func forFile(_ url: URL, duration: Double) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "flac": return "FLAC"
        case "wav", "aif", "aiff", "caf": return ext == "wav" ? "WAV" : "AIFF"
        case "alac": return "ALAC"
        default: break
        }
        let name = ext == "mp3" ? "MP3" : (["m4a", "aac", "m4b"].contains(ext) ? "AAC" : ext.uppercased())
        guard duration > 0,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return name }
        let kbps = Double(size) * 8 / duration / 1000
        if ext == "m4a", kbps > 500 { return "ALAC" }       // lossless in an .m4a
        let steps = [320, 256, 192, 160, 128, 96, 64]
        let snapped = steps.min { abs(Double($0) - kbps) < abs(Double($1) - kbps) } ?? Int(kbps)
        return "\(name) \(abs(Double(snapped) - kbps) / kbps < 0.12 ? snapped : Int(kbps.rounded()))"
    }
}

