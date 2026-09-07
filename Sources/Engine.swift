import Cocoa
import Carbon

/// キー入力を監視し，日本語IMEの「変換」に相当する操作を英語入力に持ち込む中核．
///
/// CGEventTap を使うので AppKit 非対応アプリ (VS Code / Chrome / ターミナル) でも動く．
/// コールバックは main run loop 上で走るため，絶対に重い処理を書かないこと．
/// 候補生成は CandidateEngine.queue に逃がしている．
///
/// 操作モデル (日本語IMEに合わせている):
///   打つ → 右Shift単押しで変換 → 右Shift連打で次候補 → Enter/Space で確定 → Esc で取り消し
final class Engine {

    private let candidates = CandidateEngine()
    private var bar: CandidateBar!
    private var tap: CFMachPort?

    // MARK: 状態

    /// 打ちかけの単語（未変換）
    private var buffer = ""
    /// 変換中かどうか．nil なら非変換．
    private var conv: Conversion?
    /// 候補計算のデバウンス／古い結果破棄のための世代番号
    private var generation = 0
    /// 自分が注入したイベントを識別する印
    private let injectMark: Int64 = 0x5350_4C42  // "SPLB"
    private var kanaMode = false
    /// 語義の非同期取得が古い候補のものでないかを見るための番号
    private var defToken = 0

    /// 変換キーを使わず，打っている最中から候補を出し続けるモード
    var alwaysShow = true { didSet { if !alwaysShow && conv == nil { bar.hide() } } }
    var enabled = true { didSet { if !enabled { reset() } } }

    /// 候補ウィンドウを画面のどこに出すか．
    var placement: CandidateBar.Placement {
        get { bar.placement }
        set { bar.placement = newValue }
    }

    /// 位置の判定結果を候補ウィンドウに出す．効かないアプリの切り分け用．
    var debugPlacement: Bool {
        get { bar.debug }
        set { bar.debug = newValue }
    }

    private struct Conversion {
        let original: String        // 元の綴り
        var list: [String]          // 候補（末尾に original を入れて一周できるようにする）
        var index: Int              // いま当てている候補
        var placed: String          // いま実際にアプリ側へ置いてある文字列
    }

    // 右Shift単押しの検出用
    private var rShiftDownAt: CFAbsoluteTime?
    private var keyPressedWhileShift = false
    private let soloTapLimit: CFAbsoluteTime = 0.4
    private static let rightShiftKeycode: Int64 = 60
    private static let rightShiftFlagBit: UInt64 = 0x0004   // NX_DEVICERSHIFTKEYMASK

    private let digitKeycodes: [Int64] = [18, 19, 20, 21, 23]  // 1,2,3,4,5

    init() {
        bar = CandidateBar { [weak self] i in self?.confirm(index: i) }
        observeInputSource()
        observeAppSwitch()
    }

    // MARK: - 起動

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                Unmanaged<Engine>.fromOpaque(refcon!).takeUnretainedValue().handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - イベント処理 (main thread / 軽量に保つこと)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard enabled else { return pass }
        if event.getIntegerValueField(.eventSourceUserData) == injectMark { return pass }

        if type == .leftMouseDown { keyPressedWhileShift = true; reset(); return pass }

        // パスワード欄などセキュア入力中は完全に停止
        if IsSecureEventInputEnabled() { reset(); return pass }
        // 日本語IMEのかな入力中は変換候補と衝突するので黙る
        if kanaMode { reset(); return pass }

        if type == .flagsChanged { return handleFlags(event: event) == .swallow ? nil : pass }
        guard type == .keyDown else { return pass }
        return handleKeyDown(event: event) == .swallow ? nil : pass
    }

    /// このキーをアプリへ通すか，握りつぶすか
    private enum Disposition { case pass, swallow }

    /// 右Shiftの単押し（押してから離すまでに他キーが挟まらない）を「変換キー」とみなす．
    private func handleFlags(event: CGEvent) -> Disposition {
        guard event.getIntegerValueField(.keyboardEventKeycode) == Engine.rightShiftKeycode else { return .pass }
        let isDown = (event.flags.rawValue & Engine.rightShiftFlagBit) != 0

        if isDown {
            rShiftDownAt = CFAbsoluteTimeGetCurrent()
            keyPressedWhileShift = false
        } else if let t = rShiftDownAt, !keyPressedWhileShift,
                  CFAbsoluteTimeGetCurrent() - t < soloTapLimit {
            rShiftDownAt = nil
            convertKeyPressed()
        } else {
            rShiftDownAt = nil
        }
        return .pass   // Shift自体は握りつぶさずアプリへ通す
    }

    private func handleKeyDown(event: CGEvent) -> Disposition {
        keyPressedWhileShift = true

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)

        // ⌘1〜⌘5 は候補が出ている間だけ横取りする
        // ⌘D: いま当たっている語を辞書アプリで引く
        if cmd, keycode == 2, let word = focusedWord() {
            openInDictionary(word)
            return .swallow
        }

        let visibleCount = conv?.list.count ?? barItems.count
        if cmd, visibleCount > 0, let idx = digitKeycodes.firstIndex(of: keycode), idx < visibleCount {
            DispatchQueue.main.async { [weak self] in self?.confirm(index: idx) }
            return .swallow
        }

        // --- 変換中の操作 ---
        if let active = conv {
            switch keycode {
            case 36, 76:  confirm(index: active.index);                  return .swallow  // Enter: 確定
            case 49:      confirm(index: active.index, thenSpace: true);  return .swallow  // Space: 確定して空白
            case 53:      cancelConversion();                            return .swallow  // Esc: 元に戻す
            case 125, 48: cycle(+1);                                     return .swallow  // ↓ / Tab: 次候補
            case 126:     cycle(-1);                                     return .swallow  // ↑: 前候補
            default:
                // それ以外のキーはいまの候補で確定し，そのキー自体はアプリへ通す
                finishConversion()
                return .pass
            }
        }

        if ctrl || cmd { reset(); return .pass }

        // --- 通常入力: 打ちかけの単語を追う ---
        switch keycode {
        case 53:  reset(); return .pass                             // Esc
        case 51:                                                    // Backspace
            if !buffer.isEmpty { buffer.removeLast(); refreshAlwaysShow() } else { reset() }
            return .pass
        case 123...126, 115, 116, 119, 121:                         // 矢印 / Home / End / PageUp / PageDown
            reset(); return .pass
        default: break
        }

        let ns = NSEvent(cgEvent: event)
        guard let c = (ns?.characters ?? ns?.charactersIgnoringModifiers)?.first else { reset(); return .pass }
        if c.isLetter || c == "'" {
            buffer.append(c)
            refreshAlwaysShow()
        } else {
            reset()
        }
        return .pass
    }

    // MARK: - 変換

    /// 右Shift単押し．非変換なら変換開始，変換中なら次候補へ．
    private func convertKeyPressed() {
        if conv != nil { cycle(+1); return }
        let word = buffer
        guard word.count >= 2 else { return }

        generation &+= 1
        let gen = generation
        CandidateEngine.queue.async { [weak self] in
            guard let self else { return }
            let list = self.candidates.candidates(for: word)
            DispatchQueue.main.async {
                guard gen == self.generation, self.conv == nil, self.buffer == word else { return }
                guard !list.isEmpty else { NSSound.beep(); return }
                // 末尾に元の綴りを足しておき，一周すると元に戻れるようにする
                self.conv = Conversion(original: word, list: list + [word], index: 0, placed: word)
                self.apply(index: 0)
            }
        }
    }

    private func cycle(_ delta: Int) {
        guard let c = conv else { return }
        let n = c.list.count
        apply(index: ((c.index + delta) % n + n) % n)
    }

    /// 候補 index の文字列を実際にアプリへ書き込み，候補ウィンドウを更新する．
    private func apply(index: Int) {
        guard var c = conv, index < c.list.count else { return }
        let next = c.list[index]
        if next != c.placed {
            Injector.replace(deleting: c.placed.count, with: next, mark: injectMark)
            c.placed = next
        }
        c.index = index
        conv = c
        buffer = next
        bar.show(pending: c.original, candidates: c.list, selected: index)
        lookupDefinition(for: next, at: index)
    }

    /// 選択中の候補の語義を辞書から引いて，候補ウィンドウの2行目に出す．
    /// 「この単語で合っているか」を確かめられるようにするための表示．
    private func lookupDefinition(for word: String, at index: Int) {
        defToken &+= 1
        let token = defToken
        CandidateEngine.queue.async { [weak self] in
            guard let self, let def = Definitions.lookup(word) else { return }
            DispatchQueue.main.async {
                guard token == self.defToken, let c = self.conv,
                      c.index == index, c.list[index] == word else { return }
                self.bar.show(pending: c.original, candidates: c.list, selected: index, definition: def)
            }
        }
    }

    private func confirm(index: Int, thenSpace: Bool = false) {
        if let c = conv {
            apply(index: index)
            learn(typed: c.original, chosen: conv?.placed ?? c.list[index])
            finishConversion()
        } else {
            // 常時表示モードから直接確定した場合
            guard index < barItems.count else { return }
            let word = barItems[index]
            learn(typed: buffer, chosen: word)
            Injector.replace(deleting: buffer.count, with: word, mark: injectMark)
            reset()
        }
        if thenSpace { Injector.tap(virtualKey: 49, mark: injectMark) }
    }

    /// いま注目している語．変換中ならその候補，そうでなければ先頭候補，無ければ打ちかけの語．
    private func focusedWord() -> String? {
        if let c = conv { return c.list[c.index] }
        if let first = barItems.first { return first }
        return buffer.isEmpty ? nil : buffer
    }

    private func openInDictionary(_ word: String) {
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://" + encoded) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 選んだ結果を覚えて，次から同じ打ち間違いで最優先に出す．
    private func learn(typed: String, chosen: String) {
        guard !typed.isEmpty, typed != chosen else { return }
        CandidateEngine.queue.async { [weak self] in
            self?.candidates.learning.record(typed: typed, chosen: chosen)
        }
    }

    private func cancelConversion() {
        guard let c = conv else { return }
        if c.placed != c.original {
            Injector.replace(deleting: c.placed.count, with: c.original, mark: injectMark)
        }
        conv = nil
        buffer = c.original
        bar.hide()
    }

    private func finishConversion() {
        conv = nil
        buffer = ""
        bar.hide()
    }

    // MARK: - 常時表示モード

    private var barItems: [String] = []
    private var shownDefinition: String?

    private func refreshAlwaysShow() {
        generation &+= 1
        guard alwaysShow else { barItems = []; bar.hide(); return }
        let gen = generation
        let word = buffer
        guard !word.isEmpty else { barItems = []; bar.hide(); return }

        // 1文字目から枠は出しておく．候補が空でも引っ込めない．
        // 新しい候補が届くまでの数十msは直前の候補をそのまま見せる（毎打鍵で空にすると点滅する）．
        bar.show(pending: word, candidates: barItems, selected: nil, definition: shownDefinition)
        guard word.count >= 2 else { return }

        CandidateEngine.queue.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, gen == self.generation else { return }
            let result = self.candidates.candidates(for: word)
            let def = result.first.flatMap { Definitions.lookup($0) }
            DispatchQueue.main.async {
                guard gen == self.generation, self.conv == nil else { return }
                self.barItems = result
                self.shownDefinition = def
                self.bar.show(pending: word, candidates: result, selected: nil, definition: def)
            }
        }
    }

    private func reset() {
        if conv != nil { finishConversion() }
        buffer = ""
        barItems = []
        shownDefinition = nil
        generation &+= 1
        bar.hide()
    }

    // MARK: - 監視

    private func observeInputSource() {
        updateKanaMode()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateKanaMode(); self?.reset() }
    }

    private func updateKanaMode() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { kanaMode = false; return }
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        // 例: com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese (かな) / ....Roman (英数)
        kanaMode = id.hasSuffix(".Japanese") || id.contains("Hiragana") || id.contains("Katakana")
    }

    private func observeAppSwitch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reset() }
    }
}

/// 打ちかけの文字を消して，選んだ候補を打ち直す．
enum Injector {
    static func replace(deleting count: Int, with word: String, mark: Int64) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = mark
        for _ in 0..<count { post(source, virtualKey: 51, mark: mark); usleep(1200) }   // Backspace
        // keyboardSetUnicodeString は一度に多く積むと取りこぼすアプリがあるので刻む
        for chunk in word.chunked(8) {
            let units = Array(chunk.utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                e.setIntegerValueField(.eventSourceUserData, value: mark)
                e.post(tap: .cghidEventTap)
            }
            usleep(1200)
        }
    }

    static func tap(virtualKey: CGKeyCode, mark: Int64) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = mark
        post(source, virtualKey: virtualKey, mark: mark)
    }

    private static func post(_ source: CGEventSource, virtualKey: CGKeyCode, mark: Int64) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: mark)
            e.post(tap: .cghidEventTap)
        }
    }
}

extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = [], cur = ""
        for ch in self {
            cur.append(ch)
            if cur.count == n { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
