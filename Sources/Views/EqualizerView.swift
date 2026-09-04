import SwiftUI

/// Interactive frequency-response EQ — drag the curve to bend each of the 10
/// bands. Styled to match the app: adaptive light/dark + glass cards.
struct EqualizerView: View {
    @EnvironmentObject private var player: PlayerEngine
    private let curveHeight: CGFloat = 260
    private let range: Float = 12          // ±12 dB

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                toggleCard
                curvePanel
                presetRow
                Text("Drag the curve to shape a band · pick a preset to start")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
        }
        .background(
            LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        )
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Flat") { player.applyEQPreset(Array(repeating: 0, count: 10)) }
            }
        }
    }

    private var toggleCard: some View {
        Toggle(isOn: Binding(get: { player.eqEnabled }, set: { player.setEQEnabled($0) })) {
            Label("Equalizer", systemImage: "slider.vertical.3").font(.headline)
        }
        .tint(.accentColor)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private var curvePanel: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                let pad: CGFloat = 14
                let pts = points(in: size, pad: pad)
                ZStack {
                    grid(size)
                    fillPath(pts, size).fill(
                        LinearGradient(colors: [Color.accentColor.opacity(0.32),
                                                Color.accentColor.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                    smoothPath(pts).stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .shadow(color: Color.accentColor.opacity(0.5), radius: 6)
                    ForEach(pts.indices, id: \.self) { i in
                        Circle().fill(Color(.systemBackground))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 2)
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
            .opacity(player.eqEnabled ? 1 : 0.45)

            HStack {
                ForEach(["32", "125", "500", "2k", "8k", "16k"], id: \.self) { f in
                    Text(f).font(.caption2).foregroundStyle(.secondary)
                    if f != "16k" { Spacer() }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PlayerEngine.eqPresets) { preset in
                    Button { player.applyEQPreset(preset.gains) } label: {
                        Text(preset.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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
            let norm = (player.eqGains[i] + range) / (2 * range)
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
            Path { p in
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }.stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach([0.25, 0.75], id: \.self) { frac in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height * frac))
                    p.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                }.stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }
}
