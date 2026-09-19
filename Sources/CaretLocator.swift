import Cocoa
import ApplicationServices

/// フォーカスされているテキスト入力のキャレット位置を，画面座標（原点は左下）で返す．
///
/// アクセシビリティ API 越しに他プロセスへ問い合わせるので，
/// 応答しないアプリで固まらないよう短いタイムアウトを掛けている．
/// 対応していないアプリも多いので，どこで失敗したかを `lastNote` に残す．
enum CaretLocator {

    struct Hit {
        let rect: CGRect
        let source: String      // "キャレット" か "入力欄"
    }

    private static let timeout: Float = 0.08
    /// 直近の取得結果．うまくいかないアプリを切り分けるためのデバッグ表示に使う．
    private(set) static var lastNote = "未取得"

    /// Lets callers record why they rejected a result, for the debug readout.
    static func note(_ text: String) { lastNote = text }

    static func caret() -> Hit? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)

        guard let focused = copy(system, kAXFocusedUIElementAttribute) else {
            lastNote = "フォーカスされた要素を取得できない"
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)

        if let rect = caretBounds(of: element), rect.height > 0 {
            lastNote = "キャレットから取得"
            return Hit(rect: flip(rect), source: "キャレット")
        }
        if let rect = elementBounds(of: element), rect.height > 0 {
            lastNote = "入力欄の矩形から取得（キャレット非対応）"
            return Hit(rect: flip(rect), source: "入力欄")
        }
        lastNote = "このアプリは位置を返さない"
        return nil
    }

    /// 選択範囲（キャレット）の矩形．これが取れるのが一番正確．
    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        guard let rangeValue = copy(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

        // 長さ0だと矩形を返さないアプリがあるので最低1文字ぶん要求する．
        // 行頭にキャレットがある場合に備えて，直前の1文字でも試す．
        for query in [CFRange(location: range.location, length: max(range.length, 1)),
                      CFRange(location: max(range.location - 1, 0), length: 1)] {
            var q = query
            guard let param = AXValueCreate(.cfRange, &q) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
                  let value = out else { continue }
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 { return rect }
        }
        return nil
    }

    /// キャレットが取れないときは，入力欄そのものの矩形で代用する．
    private static func elementBounds(of element: AXUIElement) -> CGRect? {
        guard let posValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    /// アクセシビリティ API は主ディスプレイ左上を原点に下向きの y を返す．
    /// AppKit は左下原点なので反転させる．主ディスプレイは原点が (0,0) の画面．
    private static func flip(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let height = primary?.frame.height ?? 0
        return CGRect(x: rect.origin.x, y: height - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }
}
