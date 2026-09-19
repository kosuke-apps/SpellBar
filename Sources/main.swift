import Cocoa
import OSLog
import ServiceManagement

/// Records permission state at launch, to check from Terminal that permissions survived an update:
/// `/usr/bin/log show --last 5m --predicate 'subsystem == "local.spellbar"'`. Never logs anything typed.
private let launchLog = Logger(subsystem: "local.spellbar", category: "launch")

/// メニューバー常駐のみ．Dock アイコンは出さない (Info.plist の LSUIElement)．
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let engine = Engine()

    func applicationDidFinishLaunching(_ n: Notification) {
        enableLoginItemOnFirstLaunch()
        setupStatusItem()

        // アクセシビリティ権限．無ければシステム設定へ誘導するダイアログが出る．
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)

        let tapStarted = engine.start()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        launchLog.notice("""
            launch build=\(version, privacy: .public) accessibility=\(trusted, privacy: .public) \
            inputMonitoring=\(CGPreflightListenEventAccess(), privacy: .public) eventTap=\(tapStarted, privacy: .public)
            """)

        if !tapStarted {
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                               accessibilityDescription: "SpellBar")
            let a = NSAlert()
            a.messageText = "キー入力を監視できませんでした"
            a.informativeText = trusted
                ? "システム設定 → プライバシーとセキュリティ →「入力監視」で SpellBar を許可してから，アプリを再起動してください．"
                : "システム設定 → プライバシーとセキュリティ →「アクセシビリティ」と「入力監視」の両方で SpellBar を許可してから，アプリを再起動してください．"
            a.runModal()
        }
    }

    /// 初回起動時だけ自動起動を有効にする．
    /// 以後はメニューの切り替えを尊重し，勝手に登録し直さない．
    private func enableLoginItemOnFirstLaunch() {
        let key = "didSetUpLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon()

        let menu = NSMenu()

        let toggle = NSMenuItem(title: "SpellBar を有効にする", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)

        let always = NSMenuItem(title: "変換キーを使わず常に候補を表示", action: #selector(toggleAlways(_:)), keyEquivalent: "")
        always.target = self
        always.state = engine.alwaysShow ? .on : .off
        menu.addItem(always)

        let login = NSMenuItem(title: "ログイン時に自動起動", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let position = NSMenuItem(title: "候補ウィンドウの位置", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        for (title, value) in [("入力位置に追従（取れなければ画面の下）", CandidateBar.Placement.followCaret),
                               ("常に画面の下", .bottom),
                               ("常に画面の上", .top)] {
            let item = NSMenuItem(title: title, action: #selector(choosePlacement(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value.rawValue
            item.state = engine.placement == value ? .on : .off
            positionMenu.addItem(item)
        }
        positionMenu.addItem(.separator())
        let debugItem = NSMenuItem(title: "位置の判定結果を表示（デバッグ）",
                                   action: #selector(toggleDebug(_:)), keyEquivalent: "")
        debugItem.target = self
        debugItem.state = engine.debugPlacement ? .on : .off
        positionMenu.addItem(debugItem)

        position.submenu = positionMenu
        menu.addItem(position)

        menu.addItem(.separator())
        for line in ["右Shift 単押し … 変換 / 次候補 / 再変換",
                     "return … 確定",
                     "space … 確定して空白を入れる",
                     "esc … 元の綴りに戻す",
                     "⌘1〜⌘5 … その候補で直接確定",
                     "⌘D … 辞書アプリでその語を引く"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "SpellBar を終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    /// メニューバーのアイコン．
    /// 文字を並べると幅を食うので図形だけで描く．
    /// 横棒2本だと漢数字の二に見えてしまうため，下側はスペルチェックの定番である波線にしている．
    private static let statusIcon: NSImage = {
        let size = NSSize(width: 15, height: 13)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // 語を表す帯
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 8.0, width: 12, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()

            // スペルチェックの波線
            let wave = NSBezierPath()
            wave.lineWidth = 1.4
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            for i in 0...48 {
                let t = CGFloat(i) / 48
                let point = NSPoint(x: 0.8 + 13.4 * t, y: 3.4 + sin(t * .pi * 4) * 1.1)
                i == 0 ? wave.move(to: point) : wave.line(to: point)
            }
            wave.stroke()
            return true
        }
        image.isTemplate = true          // メニューバーの明暗に自動で追従する
        return image
    }()

    private func applyStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = AppDelegate.statusIcon
        button.title = ""
        button.appearsDisabled = !engine.enabled
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        engine.enabled = (item.state == .on)
        applyStatusIcon()
    }

    @objc private func toggleAlways(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        engine.alwaysShow = (item.state == .on)
    }

    @objc private func choosePlacement(_ item: NSMenuItem) {
        guard let value = CandidateBar.Placement(rawValue: item.tag) else { return }
        engine.placement = value
        for other in item.menu?.items ?? [] where other.action == #selector(choosePlacement(_:)) {
            other.state = (other === item) ? .on : .off
        }
    }

    @objc private func toggleDebug(_ item: NSMenuItem) {
        item.state = item.state == .on ? .off : .on
        engine.debugPlacement = (item.state == .on)
    }

    /// ログイン項目への登録．macOS 13 以降の SMAppService を使う．
    @objc private func toggleLoginItem(_ item: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "自動起動の設定を変更できませんでした"
            a.informativeText = "\(error.localizedDescription)\n\nシステム設定 → 一般 → ログイン項目 から手動でも追加できます．"
            a.runModal()
        }
        item.state = service.status == .enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// --selftest: 権限もUIも使わず，候補生成だけを確認するモード
if CommandLine.arguments.contains("--selftest") {
    let engine = CandidateEngine()
    let samples = ["thier", "definit", "recie", "enviroment", "occurence", "seperate",
                   "asyn", "kwar", "goroutin", "kubernets", "hello", "th",
                   "reciev", "recieve", "acknowledgem", "paramater", "recomend", "sucessful",
                   "middlewar", "postgre", "authenticat", "dockerfil"]
    let sem = DispatchSemaphore(value: 0)
    CandidateEngine.queue.async {
        for s in samples {
            let start = Date()
            let c = engine.candidates(for: s)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print(String(format: "%-12@ %4dms -> %@", s as NSString, ms, c.joined(separator: ", ")))
        }
        print("\n--- reconversion: word at caret ('|' marks the caret) ---")
        let cases: [(String, String?)] = [
            ("hello wrold|", "wrold / '' / →0"),
            ("hello wrold |", "wrold / ' ' / →0"),
            ("hello wrold, |", "wrold / ', ' / →0"),
            ("hello wrold.  |", "wrold / '.  ' / →0"),
            ("hello wrold    |", nil),                  // more separators than maxSuffix
            ("hello wr|old", "wrold / '' / →3"),
            ("hello |wrold", "wrold / '' / →5"),
            ("hello\n|", nil),                          // a line break ends the search
            ("don't|", "don't / '' / →0"),
            ("it\u{2019}s|", "it\u{2019}s / '' / →0"),
            ("a|", nil),                                // too short
            ("|", nil),
            ("x = 12|", nil),                           // digits are not a word
            ("\u{201C}quoted\u{201D} wrold.|", "wrold / '.' / →0"),
        ]
        var failures = 0
        for (input, expected) in cases {
            let caret = (input as NSString).range(of: "|").location
            let text = (input as NSString).replacingOccurrences(of: "|", with: "") as NSString
            let got = TextContext.word(in: text, caret: caret).map {
                "\($0.text) / '\($0.suffix)' / →\($0.caretToWordEnd)"
            }
            let ok = got == expected
            if !ok { failures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(input.debugDescription.padding(toLength: 28, withPad: " ", startingAt: 0))"
                  + " -> \(got ?? "nil")\(ok ? "" : "   (expected \(expected ?? "nil"))")")
        }
        print(failures == 0 ? "all \(cases.count) passed" : "\(failures) FAILED")

        print("\n--- word tracking: replayed keystrokes ('⌫' is Backspace) ---")
        // Replays keys through WordTracker the way Engine.handleKeyDown classifies them.
        func replay(_ keys: String, from start: WordTracker = WordTracker()) -> WordTracker {
            var t = start
            for k in keys {
                if k == "⌫" { _ = t.backspace() }
                else if TextContext.isWordCharacter(k) { t.letter(k) }
                else if TextContext.isInlineSeparator(k) { _ = t.separator(k) }
                else { t.reset() }
            }
            return t
        }
        var afterReceive = WordTracker(); afterReceive.placed("receive")
        let tracking: [(String, WordTracker, String?)] = [
            ("hel  ⌫⌫lo", WordTracker(), "hello / ''"),     // both spaces deleted: one word again
            ("hel  ⌫lo", WordTracker(), "lo / ''"),         // one space left: a new word
            ("hel ", WordTracker(), "hel / ' '"),
            ("hel  ", WordTracker(), "hel / '  '"),
            ("hel    ", WordTracker(), nil),                // too many separators
            ("hel ⌫⌫", WordTracker(), "he / ''"),
            ("abc⌫⌫⌫⌫", WordTracker(), nil),
            ("abc⌫⌫⌫⌫xy", WordTracker(), "xy / ''"),
            ("hel, wrold", WordTracker(), "wrold / ''"),
            ("d", afterReceive, "received / ''"),          // typing right after a confirmed word
            (", ", afterReceive, "receive / ', '"),
        ]
        var trackFailures = 0
        for (keys, start, expected) in tracking {
            let got = replay(keys, from: start).target.map { "\($0.word) / '\($0.suffix)'" }
            let ok = got == expected
            if !ok { trackFailures += 1 }
            let label = (start.finished.map { "[\($0.word)] " } ?? "") + keys
            print("\(ok ? "ok  " : "FAIL") \(label.debugDescription.padding(toLength: 24, withPad: " ", startingAt: 0))"
                  + " -> \(got ?? "nil")\(ok ? "" : "   (expected \(expected ?? "nil"))")")
        }
        print(trackFailures == 0 ? "all \(tracking.count) passed" : "\(trackFailures) FAILED")

        print("\n--- choosing between keystrokes and the app's text ---")
        typealias F = WordTracker.Finished
        typealias W = TextContext.Word
        func w(_ text: String, _ suffix: String = "", right: Int = 0, selected: Bool = false) -> W {
            W(text: text, suffix: suffix, caretToWordEnd: right, selected: selected)
        }
        let choices: [(String, F?, W?, ConversionTarget?)] = [
            ("spaces deleted: app joined the word", F(word: "lo", suffix: ""), w("hello"), .atCaret(w("hello"))),
            ("two spaces became '. '", F(word: "hel", suffix: "  "), w("hel", ". "), .atCaret(w("hel", ". "))),
            ("autocorrected, same length", F(word: "teh", suffix: " "), w("the", " "), .atCaret(w("the", " "))),
            ("app text lags one letter", F(word: "hello", suffix: ""), w("hell"), .tracked(F(word: "hello", suffix: ""))),
            ("app text lags the space", F(word: "hello", suffix: " "), w("hello"), .tracked(F(word: "hello", suffix: " "))),
            ("caret elsewhere in the word", F(word: "lo", suffix: ""), w("hello", right: 2), .tracked(F(word: "lo", suffix: ""))),
            ("unrelated word at caret", F(word: "lo", suffix: ""), w("world"), .tracked(F(word: "lo", suffix: ""))),
            ("app gives no text", F(word: "lo", suffix: ""), nil, .tracked(F(word: "lo", suffix: ""))),
            ("caret moved: only the app knows", nil, w("wrold", right: 3), .atCaret(w("wrold", right: 3))),
            ("nothing anywhere", nil, nil, nil),
        ]
        var choiceFailures = 0
        for (label, tracked, actual, expected) in choices {
            let got = ConversionTarget.choose(tracked: tracked, actual: actual)
            let ok = got == expected
            if !ok { choiceFailures += 1 }
            let shown: String = {
                switch got {
                case .tracked(let f)?: return "keys: \(f.word) '\(f.suffix)'"
                case .atCaret(let a)?: return "app:  \(a.text) '\(a.suffix)'"
                case nil: return "nil"
                }
            }()
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 36, withPad: " ", startingAt: 0)) -> \(shown)")
        }
        print(choiceFailures == 0 ? "all \(choices.count) passed" : "\(choiceFailures) FAILED")

        print("\n--- 語義 ---")
        for w in ["receive", "environment", "definitely", "separate", "occurrence", "async"] {
            print(String(format: "%-12@ %@", w as NSString, Definitions.lookup(w) ?? "(辞書になし)"))
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
