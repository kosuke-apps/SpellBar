import Cocoa
import ServiceManagement

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

        if !engine.start() {
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
        for line in ["右Shift 単押し … 変換 / 次候補",
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
