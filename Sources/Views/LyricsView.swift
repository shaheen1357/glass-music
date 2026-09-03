import SwiftUI

struct LyricLine: Identifiable {
    let id = UUID()
    let time: Double
    let text: String
}

enum LyricsLoader {
    // A .lrc sidecar sits next to the track with the same base name.
    static func sidecarURL(for track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    static func load(for track: Track) -> [LyricLine] {
        guard let content = try? String(contentsOf: sidecarURL(for: track), encoding: .utf8) else { return [] }
        return parse(content)
    }

    static func parse(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var rest = String(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                if let t = time(from: tag) { times.append(t) }
                rest = String(rest[rest.index(after: close)...])
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: t, text: text)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func time(from tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]) else { return nil }
        let secParts = parts[1].split(separator: ".")
        guard let secFirst = secParts.first, let s = Double(secFirst) else { return nil }
        var frac = 0.0
        if secParts.count > 1, let f = Double("0." + secParts[1]) { frac = f }
        return m * 60 + s + frac
    }
}

struct LyricsView: View {
    let track: Track
    @EnvironmentObject var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [LyricLine] = []

    private var currentIndex: Int? {
        let t = player.currentTime
        var idx: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= t { idx = i } else { break }
        }
        return idx
    }

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    ContentUnavailableView(
                        "No Lyrics",
                        systemImage: "quote.bubble",
                        description: Text("Add a .lrc file with the same name next to the track for synced lyrics.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.title3.weight(i == currentIndex ? .bold : .regular))
                                        .foregroundStyle(i == currentIndex ? Color.primary : .secondary)
                                        .id(i)
                                        .onTapGesture { player.seek(to: line.time) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                        .onChange(of: currentIndex) { _, newValue in
                            if let newValue { withAnimation { proxy.scrollTo(newValue, anchor: .center) } }
                        }
                    }
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .onAppear { lines = LyricsLoader.load(for: track) }
    }
}
