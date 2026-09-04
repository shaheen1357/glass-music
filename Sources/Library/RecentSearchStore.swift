import Foundation
import Combine

/// One entry in Recent Searches. Case names and associated-value LABELS are a
/// persisted schema contract — they become JSON keys, so don't rename casually.
/// We store ids only (the library is the source of truth for title/art/etc.).
enum RecentSearchItem: Codable, Hashable, Identifiable {
    case track(id: String)      // Track.id (== filename here)
    case query(text: String)    // free-text search

    /// Kind-prefixed identity for dedup + ForEach (a track id and a query that
    /// share a string must never collide).
    var id: String {
        switch self {
        case .track(let id):    return "track:\(id)"
        case .query(let text):  return "query:\(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }
}

/// A recent item resolved against the live library for rendering. Built fresh at
/// render time so it always reflects current metadata and skips deleted items.
enum ResolvedRecent: Identifiable {
    case track(Track)
    case query(String)

    var id: String {
        switch self {
        case .track(let t):  return "track:\(t.id)"
        case .query(let q):  return "query:\(q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
    }
}

/// Decode-or-nil wrapper: one corrupt / unknown-future element is skipped rather
/// than throwing away the whole array.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

@MainActor
final class RecentSearchStore: ObservableObject {
    @Published private(set) var items: [RecentSearchItem] = []

    private let fileURL: URL
    private let maxCount: Int
    private let currentSchemaVersion = 2

    init(fileURL: URL? = nil, maxCount: Int = 20) {
        self.maxCount = maxCount
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Same filename the old query-string store used, so existing history migrates.
        self.fileURL = fileURL ?? base.appendingPathComponent("searchhistory.json")
        self.items = Self.loadItems(from: self.fileURL)
    }

    // MARK: - Mutations (Spotify semantics: insert-or-move-to-front, then cap)
    func add(_ item: RecentSearchItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if items.count > maxCount { items.removeLast(items.count - maxCount) }
        persist()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    // MARK: - Persistence (versioned envelope; migrates legacy [String])
    private struct Envelope: Codable { var schemaVersion: Int; var items: [RecentSearchItem] }

    private func persist() {
        let env = Envelope(schemaVersion: currentSchemaVersion, items: items)
        if let data = try? JSONEncoder().encode(env) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func loadItems(from url: URL) -> [RecentSearchItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        // v2: versioned envelope, decoded element-wise so one bad item can't wipe it.
        struct LossyEnvelope: Decodable { var schemaVersion: Int; var items: [Failable<RecentSearchItem>] }
        if let env = try? dec.decode(LossyEnvelope.self, from: data) {
            return env.items.compactMap(\.value)
        }
        // v1 (legacy): a bare [String] of raw queries → map to .query
        if let legacy = try? dec.decode([String].self, from: data) {
            return legacy.map { .query(text: $0) }
        }
        return []   // corrupt / unknown → start fresh, don't delete the file
    }
}
