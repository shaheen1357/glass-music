import Foundation

/// Client for Radio Browser (radio-browser.info): a free, community-run directory of
/// about 62,000 internet radio stations. It asks clients to send a descriptive
/// User-Agent, to pick one of its mirror servers, and to report each play as a
/// "click" so its popularity order stays honest. Stations whose stream stopped
/// answering are flagged broken and hidden here.
///
/// Coverage is uneven: some US states are well tagged, others (Montana: 19 stations,
/// almost none with a genre) only show up when you browse the place itself.
enum RadioBrowser {
    struct Country: Identifiable, Hashable { let name: String; let code: String; let count: Int; var id: String { code } }
    struct Region: Identifiable, Hashable { let name: String; let count: Int; var id: String { name } }

    /// Listening genres, chosen by hand: the directory's own top tags are noise
    /// ("radio", "music", "estación") as much as genre.
    static let genres: [String] = [
        "oldies", "classic hits", "classic rock", "classic country", "country", "60s", "70s", "80s",
        "90s", "jazz", "blues", "soul", "classical", "rock", "pop", "hip hop", "r&b", "reggae",
        "lofi", "ambient", "chillout", "electronic", "latin", "bollywood", "news", "talk",
    ]

    private static let agent = "GlassMusic/1.0 (iOS music player)"
    private static var server: String?

    /// One of the directory's mirrors, chosen once per launch.
    private static func base() async -> String {
        if let server { return server }
        var picked = "de1.api.radio-browser.info"
        if let (data, _) = try? await URLSession.shared.data(for: request("https://all.api.radio-browser.info/json/servers")),
           let list = try? JSONDecoder().decode([ServerDTO].self, from: data),
           let any = list.map(\.name).randomElement() {
            picked = any
        }
        server = picked
        return picked
    }

    private static func request(_ s: String) -> URLRequest {
        var r = URLRequest(url: URL(string: s)!)
        r.setValue(agent, forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 15
        return r
    }

    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var c = URLComponents(string: "https://\(await base())\(path)")!
        c.queryItems = query
        let (data, _) = try await URLSession.shared.data(for: request(c.url!.absoluteString))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Stations, most played first, live ones only.
    static func stations(name: String? = nil, countryCode: String? = nil, state: String? = nil,
                         tag: String? = nil, offset: Int = 0, limit: Int = 60) async throws -> [RadioStation] {
        var q = [URLQueryItem(name: "hidebroken", value: "true"),
                 URLQueryItem(name: "order", value: "clickcount"),
                 URLQueryItem(name: "reverse", value: "true"),
                 URLQueryItem(name: "offset", value: String(offset)),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let name, !name.isEmpty { q.append(URLQueryItem(name: "name", value: name)) }
        if let countryCode { q.append(URLQueryItem(name: "countrycode", value: countryCode)) }
        if let state { q.append(URLQueryItem(name: "state", value: state)) }
        if let tag { q.append(URLQueryItem(name: "tag", value: tag)) }
        let list: [StationDTO] = try await get("/json/stations/search", q)
        return list.compactMap(\.station)
    }

    static func countries() async throws -> [Country] {
        let list: [CountryDTO] = try await get("/json/countries", [
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "stationcount"),
            URLQueryItem(name: "reverse", value: "true")])
        return list.filter { $0.stationcount > 0 && !$0.iso_3166_1.isEmpty }
            .map { Country(name: $0.name, code: $0.iso_3166_1, count: $0.stationcount) }
    }

    /// States / regions of one country. The directory's filter by country doesn't
    /// narrow this list, so it's filtered here by the country name it reports.
    static func regions(of country: Country) async throws -> [Region] {
        let list: [StateDTO] = try await get("/json/states", [
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "stationcount"),
            URLQueryItem(name: "reverse", value: "true")])
        return list.filter { $0.country == country.name && $0.stationcount > 0 && !$0.name.isEmpty }
            .map { Region(name: $0.name, count: $0.stationcount) }
    }

    /// The directory's entry for a stream address, if it has one (logo, place, genre).
    static func station(byURL url: URL) async -> RadioStation? {
        let list: [StationDTO]? = try? await get("/json/stations/byurl",
                                                  [URLQueryItem(name: "url", value: url.absoluteString)])
        return list?.compactMap(\.station).first
    }

    /// Report a play, as the directory asks; best effort.
    static func reportClick(_ uuid: String) {
        Task { _ = try? await URLSession.shared.data(for: request("https://\(await base())/json/url/\(uuid)")) }
    }

    // MARK: - Wire format
    private struct ServerDTO: Decodable { let name: String }
    private struct CountryDTO: Decodable { let name: String; let iso_3166_1: String; let stationcount: Int }
    private struct StateDTO: Decodable { let name: String; let country: String; let stationcount: Int }
    private struct StationDTO: Decodable {
        let stationuuid: String
        let name: String
        let url_resolved: String?
        let url: String?
        let homepage: String?
        let favicon: String?
        let country: String?
        let state: String?
        let tags: String?
        let codec: String?
        let bitrate: Int?

        var station: RadioStation? {
            guard let s = (url_resolved?.isEmpty == false ? url_resolved : url), let stream = URL(string: s) else { return nil }
            return RadioStation(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                streamURL: stream,
                homepage: homepage.flatMap { URL(string: $0) },
                favicon: favicon.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                country: country ?? "", state: state ?? "", tags: tags ?? "",
                codec: codec ?? "", bitrate: bitrate ?? 0, browserUUID: stationuuid)
        }
    }
}
