import Cocoa

/// 候補生成エンジン．
/// Touch Bar の入力候補と同じ NSSpellChecker を使い，
/// (1) 途中入力の補完 (2) スペル修正 (3) プログラミング用語 を混ぜて返す．
///
/// NSSpellChecker はスレッドセーフではないので，必ずこの `queue` の上だけで触ること．
final class CandidateEngine {

    static let queue = DispatchQueue(label: "spellbar.candidates")

    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    let learning = LearningStore()
    private var terms: [String] = []
    private var termsByFirst: [Character: [String]] = [:]

    let maxCandidates = 5

    init() { loadTerms() }

    // MARK: - プログラミング用語辞書

    /// ~/.config/spellbar/terms.txt があれば読み，無ければ組み込みの種辞書を使う．
    private func loadTerms() {
        let path = ("~/.config/spellbar/terms.txt" as NSString).expandingTildeInPath
        var list = CandidateEngine.seedTerms
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            list += text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        terms = Array(Set(list)).sorted()
        termsByFirst = Dictionary(grouping: terms) { Character($0.prefix(1).lowercased()) }
    }

    // MARK: - 候補生成

    func candidates(for partial: String) -> [String] {
        guard partial.count >= 3 else { return [] }
        let ns = partial as NSString
        let range = NSRange(location: 0, length: ns.length)

        // 入力そのものが正しい綴りかどうか．正しいなら「修正候補」は出さない
        // (hello に cello / jello が並ぶのを防ぐ)
        let misspelled = checker.checkSpelling(of: partial, startingAt: 0,
                                               language: "en", wrap: false,
                                               inSpellDocumentWithTag: tag,
                                               wordCount: nil).location != NSNotFound

        var out: [String] = []
        func add(_ s: String) {
            guard out.count < maxCandidates else { return }
            guard s.caseInsensitiveCompare(partial) != .orderedSame else { return }
            // 所有格・アポストロフィ形は実用性が低いので落とす
            guard !s.contains("'") || partial.contains("'") else { return }
            // "middle war" / "authentic-at" のような分割候補は打ち直しの役に立たない
            guard !(s.contains(" ") || s.contains("-")) || partial.contains("-") else { return }
            guard !out.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else { return }
            out.append(s)
        }

        // (0) 過去に自分がこの綴りから選んだ語を最優先にする
        learning.preferred(for: partial).prefix(2).forEach(add)

        // (1) プログラミング用語の前方一致: asyn -> async, asyncio
        termsMatching(prefix: partial).prefix(2).forEach(add)

        // (2) 英単語の前方一致補完: definit -> definitely, definition
        let completions = checker.completions(forPartialWordRange: range, in: partial,
                                              language: "en", inSpellDocumentWithTag: tag) ?? []
        completions.prefix(3).forEach(add)

        // (3) 綴りが崩れた用語の救済: kubernets -> kubernetes
        if misspelled { termsNear(partial).prefix(2).forEach(add) }

        // (4) スペル修正: thier -> their
        if misspelled {
            let guesses = checker.guesses(forWordRange: range, in: partial,
                                          language: "en", inSpellDocumentWithTag: tag) ?? []
            guesses.prefix(4).forEach(add)
        }

        return applyCase(of: partial, to: out)
    }

    /// 入力が Foo / FOO なら候補も合わせる．
    private func applyCase(of partial: String, to list: [String]) -> [String] {
        guard let first = partial.first else { return list }
        if partial.count > 1 && partial.allSatisfy({ $0.isUppercase }) { return list.map { $0.uppercased() } }
        if first.isUppercase { return list.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        return list
    }

    private func termsMatching(prefix: String) -> [String] {
        let p = prefix.lowercased()
        guard let c = p.first else { return [] }
        return (termsByFirst[c] ?? []).filter { $0.hasPrefix(p) && $0 != p }
    }

    private func termsNear(_ word: String) -> [String] {
        let w = word.lowercased()
        guard let c = w.first else { return [] }
        let pool = (termsByFirst[c] ?? []).filter { abs($0.count - w.count) <= 3 }
        return pool
            .map { ($0, editDistance($0, w, cap: 2)) }
            .filter { $0.1 <= 2 }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// 上限付きレーベンシュタイン距離．cap を超えたら打ち切る．
    private func editDistance(_ a: String, _ b: String, cap: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > cap { return cap + 1 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            cur[0] = i
            var best = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let cost = x[i-1] == y[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
                best = min(best, cur[j])
            }
            if best > cap { return cap + 1 }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
