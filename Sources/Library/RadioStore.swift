import Foundation
import Observation

/// Your saved radio stations. Navidrome holds the list, so the web player and any
/// other Subsonic app see the same stations; saving or removing one here changes it
/// there. Navidrome stores only name, stream and homepage, so what the directory
/// knew (logo, place, genre, format) is kept on the phone, keyed by stream address.
/// The list is cached so Radio opens instantly and shows your stations offline.
@MainActor
@Observable
final class RadioStore {
    private(set) var saved: [RadioStation] = []
    private(set) var lastError: String?
    private let store: SubsonicStore
    @ObservationIgnored private var details: [String: RadioStation] = [:]   // stream URL -> directory info

    init(store: SubsonicStore) {
        self.store = store
        details = Self.read([String: RadioStation].self, "radio-details.json") ?? [:]
        saved = Self.read([RadioStation].self, "radio-saved.json") ?? []
    }

    func isSaved(_ s: RadioStation) -> Bool { saved.contains { $0.id == s.id } }

    /// Pull the server's list; the cached one stays if the server can't be reached.
    func refresh() async {
        guard let client = store.client else { return }
        do {
            let list = try await client.radioStations()
            saved = list.compactMap { r in
                guard let s = r.streamUrl, let url = URL(string: s) else { return nil }
                var st = details[url.absoluteString]
                    ?? RadioStation(name: r.name ?? "Station", streamURL: url)
                st.name = r.name ?? st.name
                st.homepage = r.homePageUrl.flatMap { URL(string: $0) } ?? st.homepage
                st.serverID = r.id
                return st
            }
            lastError = nil
            persist()
            await fillDetails()
        } catch {
            lastError = "Couldn't load your stations from the server."
        }
    }

    /// Stations saved elsewhere (the web player, or seeded on the server) arrive with
    /// only a name and an address: look each up in the directory once for its logo,
    /// place, genre and format. Ones it doesn't know keep the plain radio glyph.
    private func fillDetails() async {
        var changed = false
        for (i, s) in saved.enumerated() where details[s.id] == nil {
            guard var found = await RadioBrowser.station(byURL: s.streamURL) else {
                details[s.id] = s                    // looked up; don't ask again
                continue
            }
            found.name = s.name
            found.streamURL = s.streamURL
            found.serverID = s.serverID
            found.homepage = s.homepage ?? found.homepage
            details[s.id] = found
            if i < saved.count { saved[i] = found }
            changed = true
        }
        if changed || !details.isEmpty { persist() }
    }

    func save(_ station: RadioStation) async {
        guard let client = store.client, !isSaved(station) else { return }
        details[station.id] = station
        do {
            try await client.createRadioStation(name: station.name, streamURL: station.streamURL,
                                                homepage: station.homepage)
            await refresh()
        } catch {
            lastError = "Couldn't save “\(station.name)” to the server."
        }
    }

    func remove(_ station: RadioStation) async {
        guard let client = store.client,
              let id = station.serverID ?? saved.first(where: { $0.id == station.id })?.serverID else { return }
        do {
            try await client.deleteRadioStation(id: id)
            await refresh()
        } catch {
            lastError = "Couldn't remove “\(station.name)” from the server."
        }
    }

    func rename(_ station: RadioStation, to name: String) async {
        guard let client = store.client, let id = station.serverID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await client.updateRadioStation(id: id, name: trimmed, streamURL: station.streamURL,
                                                homepage: station.homepage)
            await refresh()
        } catch {
            lastError = "Couldn't rename “\(station.name)”."
        }
    }

    /// A station added by hand: a stream address and a name.
    func add(name: String, streamURL: URL) async {
        await save(RadioStation(name: name, streamURL: streamURL))
    }

    // MARK: - Cache (Application Support)
    private func persist() {
        Self.write(saved, "radio-saved.json")
        Self.write(details, "radio-details.json")
    }

    private static func url(_ name: String) -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(name)
    }
    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private static func write<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url(name), options: .atomic) }
    }
}
