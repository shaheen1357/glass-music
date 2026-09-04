import SwiftUI

/// Interactive frequency-response EQ: drag the glowing curve to bend each of the
/// 10 bands. Dark "studio" aesthetic so the accent curve dazzles.
struct EqualizerView: View {
    @Environment(PlayerEngine.self) private var player
    private let curveHeight: CGFloat = 260
    private let range: Float = 12          // ±12 dB

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                toggleCard
                curvePanel
                presetRow
                Text("Drag the curve to shape a band · pick a preset to start")
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .background(backdrop)
        .preferredColorScheme(.dark)
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Flat") { player.applyEQPreset(Array(repeating: 0, count: 10)) }
                    .tint(.white)
            }
        }
    }

    // MARK: Backdrop
    private var backdrop: some View {
        LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.09),
                                Color(red: 0.10, green: 0.07, blue: 0.14)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // MARK: Enable toggle
    private var toggleCard: some View {
        Toggle(isOn: Binding(get: { player.eqEnabled }, set: { player.setEQEnabled($0) })) {
            Label("Equalizer", systemImage: "slider.vertical.3")
                .font(.headline).foregroundStyle(.white)
        }
        .tint(.accentColor)
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: The interactive curve
    private var curvePanel: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                let pad: CGFloat = 14
                let pts = points(in: size, pad: pad)
                ZStack {
                    grid(size)
                    fillPath(pts, size).fill(
                        LinearGradient(colors: [Color.accentColor.opacity(0.40),
                                                Color.accentColor.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                    smoothPath(pts).stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .shadow(color: Color.accentColor.opacity(0.7), radius: 8)
                    ForEach(pts.indices, id: \.self) { i in
                        Circle().fill(.white)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
                            .position(pts[i])
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        guard player.eqEnabled else { return }
                        let usable = size.width - 2 * pad
                        guard usable > 0 else { return }
                        let raw = ((g.location.x - pad) / usable) * 9
                        let idx = max(0, min(9, Int(raw.rounded())))
                        let frac = max(0, min(1, 1 - (g.location.y / size.height)))
                        let gain = (Float(frac) * (2 * range) - range).rounded()
                        player.setEQBand(idx, gain: gain)
                    }
                )
            }
            .frame(height: curveHeight)
            .opacity(player.eqEnabled ? 1 : 0.4)

            // frequency axis (subset to avoid crowding)
            HStack {
                ForEach(["32", "125", "500", "2k", "8k", "16k"], id: \.self) { f in
                    Text(f).font(.caption2).foregroundStyle(.white.opacity(0.4))
                    if f != "16k" { Spacer() }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    // MARK: Presets
    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PlayerEngine.eqPresets) { preset in
                    Button { player.applyEQPreset(preset.gains) } label: {
                        Text(preset.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Geometry / paths
    private func points(in size: CGSize, pad: CGFloat) -> [CGPoint] {
        let usable = size.width - 2 * pad
        return (0..<player.eqGains.count).map { i in
            let x = pad + usable * CGFloat(i) / CGFloat(player.eqGains.count - 1)
            let norm = (player.eqGains[i] + range) / (2 * range)   // 0...1
            let y = size.height * (1 - CGFloat(norm))
            return CGPoint(x: x, y: y)
        }
    }

    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        path.move(to: pts[0])
        for i in 0..<pts.count - 1 {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = (i + 2 < pts.count) ? pts[i + 2] : pts[i + 1]
            let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
        return path
    }

    private func fillPath(_ pts: [CGPoint], _ size: CGSize) -> Path {
        var path = smoothPath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }

    private func grid(_ size: CGSize) -> some View {
        ZStack {
            // 0 dB center line
            Path { p in
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }.stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // ±6 dB guides
            ForEach([0.25, 0.75], id: \.self) { frac in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height * frac))
                    p.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                }.stroke(.white.opacity(0.06), lineWidth: 1)
            }
        }
    }
}
