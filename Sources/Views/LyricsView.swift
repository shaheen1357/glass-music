import SwiftUI

/// Full-screen lyrics: blurred-artwork glass backdrop, synced karaoke highlight
/// + auto-scroll when timed lyrics exist, plain scroll otherwise.
struct LyricsView: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var synced: [LyricLine] = []
    @State private var plain: String?
    @State private var loading = true
    @State private var userScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    // Last line whose timestamp has passed (binary search — cheap per tick).
    private var activeIndex: Int? {
        guard !synced.isEmpty else { return nil }
        let t = player.currentTime
        var lo = 0, hi = synced.count - 1, ans: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if synced[mid].time <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)   // .background can't inflate content width (ZStack could)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    // MARK: - Backdrop (blurred cover + material + scrim)
    @ViewBuilder private var backdrop: some View {
        Group {
            if let ui = track.artwork {
                Image(uiImage: ui)
                    .resizable().scaledToFill()
                    .blur(radius: 60, opaque: true)
                    .overlay(Color.black.opacity(0.28))
                    .overlay(.ultraThinMaterial)
            } else {
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            Button("Done") { dismiss() }.font(.body.weight(.semibold)).tint(.white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if loading {
            Spacer(); ProgressView().tint(.white); Spacer()
        } else if !synced.isEmpty {
            karaoke
        } else if let plain {
            ScrollView {
                Text(plain)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .textSelection(.enabled)
            }
        } else {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble").font(.system(size: 44)).foregroundStyle(.white.opacity(0.45))
                Text("No Lyrics").font(.title3.bold()).foregroundStyle(.white)
                Text("No synced or embedded lyrics found for this track.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            }
            .padding(40)
            Spacer()
        }
    }

    // MARK: - Karaoke
    private var karaoke: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(synced.enumerated()), id: \.element.id) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 27, weight: i == activeIndex ? .bold : .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .opacity(opacity(for: i))
                            .scaleEffect(i == activeIndex ? 1.0 : 0.97, anchor: .leading)
                            .animation(.easeInOut(duration: 0.3), value: activeIndex)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: line.time) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 44)
            }
            .mask(edgeFade)
            .onChange(of: activeIndex) { _, newValue in
                guard let newValue, !userScrolling else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    proxy.scrollTo(newValue, anchor: UnitPoint(x: 0.5, y: 0.38))
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    userScrolling = true
                    resumeTask?.cancel()
                    resumeTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        userScrolling = false
                    }
                }
            )
        }
    }

    private func opacity(for i: Int) -> Double {
        guard let a = activeIndex else { return 0.55 }
        if i == a { return 1 }
        return abs(i - a) == 1 ? 0.5 : 0.3
    }

    private var edgeFade: LinearGradient {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.10),
            .init(color: .black, location: 0.88),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private func load() async {
        loading = true
        switch await LyricsLoader.resolve(for: track) {
        case .synced(let lines): synced = lines; plain = nil
        case .plain(let text): synced = []; plain = text
        case .none: synced = []; plain = nil
        }
        loading = false
    }
}
