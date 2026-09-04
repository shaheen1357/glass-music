import Foundation
import AVFoundation
import Accelerate

/// On-device loudness analysis for volume normalization. The library is untagged
/// (no ReplayGain), so we measure each track's RMS + peak with vDSP once, cache
/// it, and derive a clip-safe gain toward a target level. Analysis runs off the
/// main thread; the cached result is a cheap synchronous read.
enum LoudnessService {
    struct Measurement: Codable, Sendable {
        let gainDB: Double      // dB to reach the target (relative to measured RMS)
        let peak: Double        // linear peak, 1.0 == 0 dBFS
    }

    private static let targetDBFS: Double = -14   // RMS target
    private static let ceilingDBFS: Double = -1   // leave 1 dB headroom (inter-sample safety)

    /// Clip-safe gain (dB) to apply for a track, or nil if not analyzed yet.
    static func effectiveGain(for track: Track) -> Float? {
        guard let m = cached(for: track) else { return nil }
        let headroom = ceilingDBFS - 20 * log10(max(m.peak, 0.0001))  // max boost before the ceiling
        let g = min(m.gainDB, headroom)
        return Float(max(-12, min(12, g)))
    }

    static func hasMeasurement(for track: Track) -> Bool { cached(for: track) != nil }

    /// Analyze off the main thread and cache. No-op if already cached.
    static func analyzeAndCache(_ track: Track) async {
        guard cached(for: track) == nil else { return }
        let url = track.url
        let m = await Task.detached(priority: .utility) { analyze(url) }.value
        if let m { write(m, for: track) }
    }

    // MARK: - Analysis
    private static func analyze(_ url: URL) -> Measurement? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000) else { return nil }

        var sumSquares = 0.0
        var totalSamples = 0.0
        var peak: Float = 0
        while true {
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            for c in 0..<Int(format.channelCount) {
                var ms: Float = 0
                vDSP_measqv(data[c], 1, &ms, vDSP_Length(n))     // mean of squares
                sumSquares += Double(ms) * Double(n)
                totalSamples += Double(n)
                var p: Float = 0
                vDSP_maxmgv(data[c], 1, &p, vDSP_Length(n))       // max magnitude (peak)
                if p > peak { peak = p }
            }
        }
        guard totalSamples > 0 else { return nil }
        let meanSquare = sumSquares / totalSamples
        let safePeak = Double(max(peak, 0.0001))
        guard meanSquare > 0 else { return Measurement(gainDB: 0, peak: safePeak) }
        let rmsDBFS = 10 * log10(meanSquare)                     // power → 10·log10
        return Measurement(gainDB: targetDBFS - rmsDBFS, peak: safePeak)
    }

    // MARK: - Cache (Application Support/Loudness/<key>.json)
    private static var dir: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("Loudness", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func key(_ track: Track) -> String {
        let safe = track.id.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "_" }
        return String(String(safe).prefix(120))
    }

    private static func cached(for track: Track) -> Measurement? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(key(track) + ".json")) else { return nil }
        return try? JSONDecoder().decode(Measurement.self, from: data)
    }

    private static func write(_ m: Measurement, for track: Track) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: dir.appendingPathComponent(key(track) + ".json"), options: .atomic)
        }
    }
}
