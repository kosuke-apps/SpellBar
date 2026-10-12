import Foundation
import CoreServices

/// Looks a word up in the dictionaries built into macOS.
///
/// The point is to let someone writing English check "is this the word I meant?", so the pronunciation and
/// inflections are stripped and only the meaning is kept, on one line.
///
/// macOS offers no public way to choose a dictionary: the lookup goes through the user's active dictionaries in
/// the order set in Dictionary.app, and the first one with an entry answers. The result can therefore be a
/// Japanese gloss from an English-Japanese dictionary or an English definition from an English one, and both are
/// condensed here.
enum Definitions {

    private static var cache: [String: String?] = [:]
    /// Parts of speech in Japanese dictionaries. Plain 動詞 must come after 他動詞, 自動詞 and 助動詞.
    private static let japanesePartsOfSpeech = ["他動詞", "自動詞", "名詞", "形容詞", "副詞", "前置詞", "接続詞", "代名詞", "間投詞", "助動詞", "動詞"]
    /// Parts of speech in English dictionaries. Multi-word ones come first so that "auxiliary verb" is not read
    /// as a bare "verb".
    private static let englishPartsOfSpeech = [
        "auxiliary verb", "modal verb", "phrasal verb", "combining form",
        "noun", "verb", "adjective", "adverb", "preposition", "conjunction", "pronoun", "interjection",
        "exclamation", "determiner", "abbreviation", "prefix", "suffix", "particle", "symbol", "contraction",
    ]
    private static let maxLength = 80

    /// Call this on `CandidateEngine.queue`.
    static func lookup(_ word: String) -> String? {
        if let hit = cache[word] { return hit }
        let range = CFRangeMake(0, (word as NSString).length)
        let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?
        let cleaned = raw.flatMap(condense)
        cache[word] = cleaned
        return cleaned
    }

    /// Picks a readable single line out of a dictionary's raw text.
    static func condense(_ raw: String) -> String? {
        let japanese = raw.contains { isJapanese($0) }
        return japanese ? condenseJapanese(raw) : condenseEnglish(raw)
    }

    // MARK: English

    /// "defenestrate de·fen·es·trate | dēˈfenəˌstrāt | verb [with object] 1 rare throw (someone) out of a
    /// window: she had made up her mind … 2 remove or dismiss …" becomes "rare throw (someone) out of a window".
    private static func condenseEnglish(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\n", with: " ")

        // Drop the headword, its syllables and the pronunciation, which end at the second bar.
        if let open = s.firstIndex(of: "|"), let close = s[s.index(after: open)...].firstIndex(of: "|") {
            s = String(s[s.index(after: close)...])
        }

        // The first part of speech, with its qualifiers ("[with object]", "(plural …)"), marks where the
        // meaning begins. Without it the text is not in a shape this knows how to read.
        let pattern = "\\b(?:\(englishPartsOfSpeech.joined(separator: "|")))\\b(?:\\s*(?:\\[[^\\]]*\\]|\\([^)]*\\)))*"
        guard let found = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              s.distance(from: s.startIndex, to: found.lowerBound) < 40 else { return nil }
        s = String(s[found.upperBound...])

        // Drop the sense number, and keep the first sense up to the example sentence.
        s = s.replacingOccurrences(of: "^[\\s\\d.]+", with: "", options: .regularExpression)
        if let second = s.range(of: "\\s2\\s", options: .regularExpression) { s = String(s[..<second.lowerBound]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }

        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") || s.hasSuffix(";") { s.removeLast() }

        guard s.count >= 3 else { return nil }
        guard s.count > maxLength else { return s }
        // Cut at a word boundary rather than in the middle of a word.
        let cut = String(s.prefix(maxLength))
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut) + "…"
    }

    // MARK: Japanese

    /// Drops the headword, pronunciation, inflections and part of speech so that the text starts at the first
    /// meaning.
    private static func condenseJapanese(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\n", with: " ")

        // Drop the notes, and the bars around pronunciation and inflections such as | risíːv |.
        s = s.replacingOccurrences(of: "〖[^〗]*〗", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "｟[^｠]*｠", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\|[^|]*\\|", with: " ", options: .regularExpression)
        // Drop the part of speech and the inflection notation that follows it (名詞複～s, 動詞～s, …).
        s = s.replacingOccurrences(of: "(?:\(japanesePartsOfSpeech.joined(separator: "|")))(?:複)?(?:～\\S*)?",
                                   with: " ", options: .regularExpression)

        // Start at the first Japanese meaning, including any opening brackets (and the ellipsis of "«…に関する»")
        // just before it, so that a closing bracket is never left without its partner.
        let chars = Array(s)
        guard let head = firstJapaneseRun(chars) else { return nil }
        var from = head
        while from > 0, "(（〈《«【〔「『…".contains(chars[from - 1]) { from -= 1 }

        let body = String(chars[from...])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard body.count >= 2 else { return nil }
        return body.count > maxLength ? String(body.prefix(maxLength)) + "…" : body
    }

    /// The position of the first run of two or more Japanese characters.
    private static func firstJapaneseRun(_ chars: [Character], minLength: Int = 2) -> Int? {
        var run = 0
        for (i, c) in chars.enumerated() {
            if isJapanese(c) {
                run += 1
                if run >= minLength { return i - run + 1 }
            } else {
                run = 0
            }
        }
        return nil
    }

    private static func isJapanese(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v)      // hiragana and katakana
            || (0x4E00...0x9FFF).contains(v)      // kanji
            || (0xFF61...0xFF9F).contains(v)      // half-width katakana and the half-width middle dot
            || v == 0x3005                        // 々
    }
}
