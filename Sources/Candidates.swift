import Cocoa

/// The candidate engine.
/// It uses `NSSpellChecker`, the same engine as the Touch Bar's typing suggestions, and mixes
/// (1) completions of a word typed so far, (2) spelling corrections and (3) programming terms.
///
/// `NSSpellChecker` is not thread-safe, so touch it only on this `queue`.
final class CandidateEngine {

    static let queue = DispatchQueue(label: "spellbar.candidates")

    private let checker = NSSpellChecker.shared
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    let learning = LearningStore()
    private var terms: [String] = []
    private var termsByFirst: [Character: [String]] = [:]

    let maxCandidates = 5

    init() { loadTerms() }

    // MARK: - Programming terms

    /// Reads ~/.config/spellbar/terms.txt when it exists and adds the built-in seed list.
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

    // MARK: - Candidates

    func candidates(for partial: String) -> [String] {
        guard partial.count >= 3 else { return [] }
        let ns = partial as NSString
        let range = NSRange(location: 0, length: ns.length)

        // Whether the input itself is spelled correctly. If it is, no corrections are offered
        // (so "hello" is not followed by "cello" and "jello").
        let misspelled = checker.checkSpelling(of: partial, startingAt: 0,
                                               language: "en", wrap: false,
                                               inSpellDocumentWithTag: tag,
                                               wordCount: nil).location != NSNotFound

        var out: [String] = []
        func add(_ s: String) {
            guard out.count < maxCandidates else { return }
            guard s.caseInsensitiveCompare(partial) != .orderedSame else { return }
            // Possessive and apostrophe forms are rarely useful, so they are dropped.
            guard !s.contains("'") || partial.contains("'") else { return }
            // Split candidates such as "middle war" or "authentic-at" do not help with retyping.
            guard !(s.contains(" ") || s.contains("-")) || partial.contains("-") else { return }
            guard !out.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else { return }
            out.append(s)
        }

        // (0) Words the user chose for this spelling before come first.
        learning.preferred(for: partial).prefix(2).forEach(add)

        // (1) Programming terms that start with the input: asyn -> async, asyncio
        termsMatching(prefix: partial).prefix(2).forEach(add)

        // (2) Completions of English words: definit -> definitely, definition
        let completions = checker.completions(forPartialWordRange: range, in: partial,
                                              language: "en", inSpellDocumentWithTag: tag) ?? []
        completions.prefix(3).forEach(add)

        // (3) Rescuing a term with broken spelling: kubernets -> kubernetes
        if misspelled { termsNear(partial).prefix(2).forEach(add) }

        // (4) Spelling corrections: thier -> their
        if misspelled {
            let guesses = checker.guesses(forWordRange: range, in: partial,
                                          language: "en", inSpellDocumentWithTag: tag) ?? []
            guesses.prefix(4).forEach(add)
        }

        return applyCase(of: partial, to: out)
    }

    /// Matches the case of the input: Foo gives Foo…, FOO gives FOO….
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

    /// Levenshtein distance with a ceiling; stops as soon as it exceeds `cap`.
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
