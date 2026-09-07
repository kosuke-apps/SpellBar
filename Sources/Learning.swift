import Foundation

/// 確定した「打ち間違い → 選んだ語」の対応を覚えて，次から最優先で出す．
/// 自分で辞書を育てる必要が無いよう，普通に使っているだけで貯まるようにしてある．
/// アクセスは必ず CandidateEngine.queue の上だけで行うこと．
final class LearningStore {

    private var map: [String: [String: Int]] = [:]   // 打った綴り -> (選んだ語 -> 回数)
    private let path: String
    private var dirty = false

    init() {
        let dir = ("~/.config/spellbar" as NSString).expandingTildeInPath
        path = dir + "/learned.json"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        load()
    }

    /// この綴りに対して過去に選ばれた語を，選ばれた回数の多い順で返す．
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

    /// 覚えた対応の総数．設定画面などで見せる用．
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
