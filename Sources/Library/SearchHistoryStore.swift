import Foundation
import Combine

@MainActor
final class SearchHistoryStore: ObservableObject {
    @Published private(set) var recent: [String] = []
    private let fileURL: URL
    private let maxItems = 15

    init(fileURL: URL? = nil) {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base.appendingPathComponent("searchhistory.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return }
        recent = arr
    }
    private func save() {
        if let data = try? JSONEncoder().encode(recent) { try? data.write(to: fileURL, options: .atomic) }
    }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        recent.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recent.insert(q, at: 0)
        if recent.count > maxItems { recent = Array(recent.prefix(maxItems)) }
        save()
    }
    func remove(_ query: String) { recent.removeAll { $0 == query }; save() }
    func clear() { recent.removeAll(); save() }
}
