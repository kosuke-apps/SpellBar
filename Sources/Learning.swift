import Foundation

/// Remembers which word was chosen for which misspelling, and offers it first next time.
/// Nothing has to be maintained by hand: it fills up just by using the app.
/// Access it only on `CandidateEngine.queue`.
final class LearningStore {

    private var map: [String: [String: Int]] = [:]   // typed spelling -> (chosen word -> times chosen)
    private let path: String
    private var dirty = false

    init() {
        let dir = ("~/.config/spellbar" as NSString).expandingTildeInPath
        path = dir + "/learned.json"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        load()
    }

    /// The words chosen for this spelling before, most often chosen first.
    func preferred(for typed: String) -> [String] {
        guard let counts = map[typed.lowercased()] else { return [] }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    func record(typed: String, chosen: String) {
        let key = typed.lowercased()
        guard key != chosen.lowercased() else { return }
        map[key, default: [:]][chosen, default: 0] += 1
        dirty = true
        save()
    }

    /// The total number of remembered pairs.
    var count: Int { map.values.reduce(0) { $0 + $1.count } }

    private func load() {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else { return }
        map = raw
    }

    private func save() {
        guard dirty else { return }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        dirty = false
    }
}
