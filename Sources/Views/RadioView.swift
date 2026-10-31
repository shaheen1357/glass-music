import SwiftUI

// MARK: - Radio tab
/// Your saved stations on top (a shelf, like Home), then browse cards (like Search),
/// and the search bar finds any station by name. Stations play live through the
/// streaming player; saving one puts it on the Navidrome server.
struct RadioView: View {
    @Environment(RadioStore.self) private var radio
    @State private var query = ""
    @State private var results: [RadioStation] = []
    @State private var searching = false
    @State private var showAdd = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private struct Card: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let colors: [Color]
        let destination: AnyView
    }

    private var cards: [Card] {
        [
            Card(title: "Popular in the US", icon: "flag.fill",
                 colors: [Color(red: 0.85, green: 0.20, blue: 0.30), Color(red: 0.25, green: 0.25, blue: 0.65)],
                 destination: AnyView(StationsScreen(title: "Popular in the US") { offset in
                     try await RadioBrowser.stations(countryCode: "US", offset: offset)
                 })),
            Card(title: "Oldies & Classics", icon: "record.circle",
                 colors: [Color(red: 0.80, green: 0.55, blue: 0.20), Color(red: 0.55, green: 0.25, blue: 0.15)],
                 destination: AnyView(StationsScreen(title: "Oldies & Classics") { offset in
                     try await RadioBrowser.stations(tag: "oldies", offset: offset)
                 })),
            Card(title: "By Place", icon: "map.fill",
                 colors: [Color(red: 0.20, green: 0.55, blue: 0.85), Color(red: 0.10, green: 0.35, blue: 0.60)],
                 destination: AnyView(PlacesView())),
            Card(title: "By Genre", icon: "guitars.fill",
                 colors: [Color(red: 0.55, green: 0.30, blue: 0.85), Color(red: 0.30, green: 0.15, blue: 0.55)],
                 destination: AnyView(GenresView())),
        ]
    }

    var body: some View {
        NavigationStack {
            Group {
                if !trimmed.isEmpty {
                    StationList(stations: results, loading: searching)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            yourStations
                            browse
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Radio")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Stations")
            .task(id: trimmed) {
                guard !trimmed.isEmpty else { results = []; return }
                try? await Task.sleep(nanoseconds: 400_000_000)      // wait for typing to pause
                guard !Task.isCancelled else { return }
                searching = true
                results = (try? await RadioBrowser.stations(name: trimmed)) ?? []
                searching = false
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a Station")
                }
            }
            .sheet(isPresented: $showAdd) { AddStationView() }
            .task { await radio.refresh() }
            .refreshable { await radio.refresh() }
        }
    }

    // Saved on the server: a shelf of station tiles.
    private var yourStations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Stations").font(.title2.bold()).padding(.horizontal)
            if radio.saved.isEmpty {
                Text("Save a station from its menu and it appears here, and in Navidrome.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(radio.saved) { StationTile(station: $0) }
                    }
                    .padding(.horizontal)
                }
            }
            if let err = radio.lastError {
                Text(err).font(.footnote).foregroundStyle(.red).padding(.horizontal)
            }
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browse").font(.title2.bold()).padding(.horizontal)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(cards) { card in
                    NavigationLink { card.destination } label: { cardView(card) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // Same card as Search's Browse grid.
    private func cardView(_ card: Card) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: card.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(card.title).font(.headline).foregroundStyle(.white).padding(12)
            Image(systemName: card.icon)
                .font(.title)
                .foregroundStyle(.white.opacity(0.9))
                .rotationEffect(.degrees(25))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 6, y: 10)
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Playing a station
@MainActor
enum RadioPlayback {
    /// Fetch the logo (briefly) so the player and lock screen show it, then play live.
    static func play(_ station: RadioStation, player: PlayerEngine) {
        Task {
            var art: Data?
            if let logo = station.favicon {
                var r = URLRequest(url: logo)
                r.timeoutInterval = 4
                art = try? await URLSession.shared.data(for: r).0
            }
            player.play(tracks: [station.asTrack(artwork: art)], startAt: 0)
            if let uuid = station.browserUUID { RadioBrowser.reportClick(uuid) }
        }
    }
}

// MARK: - Pieces
/// A station's logo, or a radio glyph on the app's gradient while there isn't one.
struct StationArt: View {
    let station: RadioStation
    var corner: CGFloat = 6

    var body: some View {
        AsyncImage(url: station.favicon) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title3).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// A saved station on the shelf.
private struct StationTile: View {
    let station: RadioStation
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Button { RadioPlayback.play(station, player: player) } label: {
            VStack(alignment: .leading, spacing: 6) {
                StationArt(station: station, corner: 8).frame(width: 130, height: 130)
                Text(station.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { StationActions(station: station) }
    }
}

/// A station in a list: logo, name, where and what, its format, and a menu.
struct StationRow: View {
    let station: RadioStation
    @Environment(PlayerEngine.self) private var player

    private var isCurrent: Bool { player.currentTrack?.id == RadioStation.trackPrefix + station.id }

    var body: some View {
        HStack(spacing: 8) {
            Button { RadioPlayback.play(station, player: player) } label: {
                HStack(spacing: 12) {
                    StationArt(station: station).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name)
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(1)
                        if !station.subtitle.isEmpty {
                            Text(station.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let format = station.formatLabel {
                        Text(format)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { StationActions(station: station) } label: { TrackMenuLabel() }
                .buttonStyle(.plain)
        }
    }
}

/// Save / remove / rename / website — the same everywhere a station appears.
struct StationActions: View {
    let station: RadioStation
    @Environment(RadioStore.self) private var radio
    @Environment(PlayerEngine.self) private var player
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { RadioPlayback.play(station, player: player) } label: { Label("Play", systemImage: "play.fill") }
        if radio.isSaved(station) {
            Button(role: .destructive) { Task { await radio.remove(station) } } label: {
                Label("Remove from Your Stations", systemImage: "minus.circle")
            }
        } else {
            Button { Task { await radio.save(station) } } label: {
                Label("Save to Your Stations", systemImage: "plus.circle")
            }
        }
        if let home = station.homepage {
            Button { openURL(home) } label: { Label("Station Website", systemImage: "safari") }
        }
    }
}

/// A list of stations with paging ("Load More") for directory results.
struct StationList: View {
    let stations: [RadioStation]
    var loading = false
    var onLoadMore: (() -> Void)? = nil

    var body: some View {
        List {
            ForEach(stations) { StationRow(station: $0) }
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if stations.isEmpty {
                Text("No stations found.").foregroundStyle(.secondary).listRowSeparator(.hidden)
            } else if let onLoadMore {
                Button("Load More", action: onLoadMore).frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
    }
}

/// Any directory listing: loads the first page, then more on request.
struct StationsScreen: View {
    let title: String
    let load: (Int) async throws -> [RadioStation]
    @State private var stations: [RadioStation] = []
    @State private var loading = true
    @State private var more = true
    @State private var failed = false

    init(title: String, load: @escaping (Int) async throws -> [RadioStation]) {
        self.title = title
        self.load = load
    }

    var body: some View {
        StationList(stations: stations, loading: loading,
                    onLoadMore: more ? { Task { await page() } } : nil)
            .overlay {
                if failed && stations.isEmpty {
                    ContentUnavailableView("Can't Reach the Station Directory",
                                           systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text("Check your connection and pull to try again."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task { if stations.isEmpty { await page() } }
            .refreshable { stations = []; more = true; await page() }
    }

    private func page() async {
        loading = true
        do {
            let next = try await load(stations.count)
            let seen = Set(stations.map(\.id))
            stations += next.filter { !seen.contains($0.id) }
            more = next.count >= 60
            failed = false
        } catch {
            failed = true
        }
        loading = false
    }
}

// MARK: - By place
private struct PlacesView: View {
    @State private var countries: [RadioBrowser.Country] = []
    @State private var filter = ""

    private var shown: [RadioBrowser.Country] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? countries : countries.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        List(shown) { c in
            NavigationLink { RegionsView(country: c) } label: {
                HStack {
                    Text(flag(c.code))
                    Text(c.name)
                    Spacer()
                    Text("\(c.count)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .overlay { if countries.isEmpty { ProgressView() } }
        .searchable(text: $filter, prompt: "Countries")
        .navigationTitle("By Place")
        .navigationBarTitleDisplayMode(.inline)
        .task { if countries.isEmpty { countries = (try? await RadioBrowser.countries()) ?? [] } }
    }

    private func flag(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(Character.init))
    }
}

/// A country: all of it, or one state / region (Texas, Montana, California...).
private struct RegionsView: View {
    let country: RadioBrowser.Country
    @State private var regions: [RadioBrowser.Region] = []
    @State private var loaded = false

    var body: some View {
        List {
            NavigationLink {
                StationsScreen(title: country.name) { offset in
                    try await RadioBrowser.stations(countryCode: country.code, offset: offset)
                }
            } label: {
                Label("All of \(country.name)", systemImage: "globe")
            }
            ForEach(regions) { r in
                NavigationLink {
                    StationsScreen(title: r.name) { offset in
                        try await RadioBrowser.stations(countryCode: country.code, state: r.name, offset: offset)
                    }
                } label: {
                    HStack {
                        Text(r.name)
                        Spacer()
                        Text("\(r.count)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if !loaded { ProgressView() } }
        .navigationTitle(country.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !loaded {
                regions = (try? await RadioBrowser.regions(of: country)) ?? []
                loaded = true
            }
        }
    }
}

// MARK: - By genre
private struct GenresView: View {
    var body: some View {
        List(RadioBrowser.genres, id: \.self) { tag in
            NavigationLink {
                StationsScreen(title: tag.capitalized) { offset in
                    try await RadioBrowser.stations(tag: tag, offset: offset)
                }
            } label: {
                Text(tag.capitalized)
            }
        }
        .listStyle(.plain)
        .navigationTitle("By Genre")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Add by address
private struct AddStationView: View {
    @Environment(RadioStore.self) private var radio
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var saving = false

    private var url: URL? {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: a), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Stream address (https://…)", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("The station's direct stream link, not its web page. It's saved to Navidrome, so it shows everywhere.")
                }
            }
            .navigationTitle("Add a Station")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let url else { return }
                        saving = true
                        Task {
                            await radio.add(name: name.trimmingCharacters(in: .whitespaces), streamURL: url)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(url == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }
}
