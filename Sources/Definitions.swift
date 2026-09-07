import Foundation
import CoreServices

/// macOS 内蔵の辞書から語義を引く．
/// 英語を書いていて「この単語で合っているか」を確かめられるのが狙いなので，
/// 発音記号や活用の羅列は削って，語義だけを1行に詰める．
enum Definitions {

    private static var cache: [String: String?] = [:]
    private static let posMarkers = ["他動詞", "自動詞", "名詞", "形容詞", "副詞", "前置詞", "接続詞", "代名詞", "間投詞", "助動詞", "動詞"]   // 「動詞」は他動詞・自動詞・助動詞より後ろに置くこと

    /// CandidateEngine.queue の上から呼ぶこと．
    static func lookup(_ word: String) -> String? {
        if let hit = cache[word] { return hit }
        let range = CFRangeMake(0, (word as NSString).length)
        let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?
        let cleaned = raw.flatMap(condense)
        cache[word] = cleaned
        return cleaned
    }

    /// 辞書の生テキストから，読みやすい1行を取り出す．
    /// 見出し語・発音記号・活用・品詞表示を落として，最初の語義から始まるようにする．
    private static func condense(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\n", with: " ")

        // 注記と，| risíːv | のような発音・活用の囲みを落とす
        s = s.replacingOccurrences(of: "〖[^〗]*〗", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "｟[^｠]*｠", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\|[^|]*\\|", with: " ", options: .regularExpression)
        // 品詞表示とそれに続く活用表記（名詞複～s / 動詞～s など）を落とす
        s = s.replacingOccurrences(of: "(?:\(posMarkers.joined(separator: "|")))(?:複)?(?:～\\S*)?",
                                   with: " ", options: .regularExpression)

        // 最初の日本語の語義から始める．直前が開き括弧ならそれも含める．
        let chars = Array(s)
        guard let head = firstJapaneseRun(chars) else { return nil }
        var from = head
        if from > 0, "(（〈《«".contains(chars[from - 1]) { from -= 1 }

        let body = String(chars[from...])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard body.count >= 2 else { return nil }
        return body.count > 80 ? String(body.prefix(80)) + "…" : body
    }

    /// 日本語の文字が2つ以上続く最初の位置．
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
        return (0x3040...0x30FF).contains(v)      // ひらがな・カタカナ
            || (0x4E00...0x9FFF).contains(v)      // 漢字
            || (0xFF61...0xFF9F).contains(v)      // 半角カタカナ・半角中黒
            || v == 0x3005                        // 々
    }
}
