import Cocoa
import ServiceManagement

/// Lives in the menu bar only: no Dock icon (`LSUIElement` in Info.plist).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let engine = Engine()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateSettingsFromPreviousIdentifier()
        enableLoginItemOnFirstLaunch()
        setupStatusItem()

        // Accessibility permission; without it macOS shows a prompt that leads to System Settings.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)

        let tapStarted = engine.start()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Log.launch.notice("""
            launch build=\(version, privacy: .public) accessibility=\(trusted, privacy: .public) \
            inputMonitoring=\(CGPreflightListenEventAccess(), privacy: .public) eventTap=\(tapStarted, privacy: .public)
            """)

        if !tapStarted {
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                               accessibilityDescription: "SpellBar")
            let a = NSAlert()
            a.messageText = String(localized: "SpellBar can't watch the keyboard")
            a.informativeText = trusted
                ? String(localized: "Allow SpellBar under System Settings → Privacy & Security → Input Monitoring, then restart the app.")
                : String(localized: "Allow SpellBar under System Settings → Privacy & Security → Accessibility and Input Monitoring, then restart the app.")
            a.runModal()
        }
    }

    private static let loginItemKey = "didSetUpLoginItem"
    /// The identifier used before the app was published, as `local.spellbar`.
    private static let previousBundleIdentifier = "local.spellbar"

    /// Enables starting at login, on the first launch only.
    /// After that the menu item decides; never register again behind the user's back.
    private func enableLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppDelegate.loginItemKey) else { return }
        defaults.set(true, forKey: AppDelegate.loginItemKey)
        try? SMAppService.mainApp.register()
    }

    /// The settings to bring over from the previous identifier's domain: every key the new domain lacks.
    static func settingsToCarry(from previous: [String: Any], into current: [String: Any]) -> [String: Any] {
        previous.filter { current[$0.key] == nil }
    }

    /// Carries the settings across the one change of bundle identifier.
    ///
    /// macOS keys preferences by bundle identifier, so the new one starts with an empty domain. The learned words
    /// live at a fixed path and are untouched.
    ///
    /// The login item is deliberately not registered here. Its old registration cannot be reached from the new
    /// identifier, and nothing records whether the user had it on, so registering would switch it on again for
    /// someone who had turned it off. The flag that the first-launch setup is done is carried, which keeps that
    /// setup from running; the user switches the login item on from the menu.
    private func migrateSettingsFromPreviousIdentifier() {
        let defaults = UserDefaults.standard
        let migratedKey = "didMigrateFromPreviousBundleIdentifier"
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        guard let previous = defaults.persistentDomain(forName: AppDelegate.previousBundleIdentifier),
              !previous.isEmpty else { return }
        let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        let carried = AppDelegate.settingsToCarry(from: previous, into: current)
        for (key, value) in carried { defaults.set(value, forKey: key) }
        Log.launch.notice("carried \(carried.count, privacy: .public) settings over from the previous bundle identifier")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: String(localized: "Enable SpellBar"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)

        let always = NSMenuItem(title: String(localized: "Always show candidates (no conversion key needed)"), action: #selector(toggleAlways(_:)), keyEquivalent: "")
        always.target = self
        always.state = engine.alwaysShow ? .on : .off
        menu.addItem(always)

        let login = NSMenuItem(title: String(localized: "Start at login"), action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let position = NSMenuItem(title: String(localized: "Candidate window position"), action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        for (title, value) in [(String(localized: "Follow the caret (bottom of the screen if unavailable)"),
                                CandidateBar.Placement.followCaret),
                               (String(localized: "Always at the bottom of the screen"), .bottom),
                               (String(localized: "Always at the top of the screen"), .top)] {
            let item = NSMenuItem(title: title, action: #selector(choosePlacement(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value.rawValue
            item.state = engine.placement == value ? .on : .off
            positionMenu.addItem(item)
        }
        positionMenu.addItem(.separator())
        let debugItem = NSMenuItem(title: String(localized: "Show how the position was found (debug)"),
                                   action: #selector(toggleDebug(_:)), keyEquivalent: "")
        debugItem.target = self
        debugItem.state = engine.debugPlacement ? .on : .off
        positionMenu.addItem(debugItem)

        position.submenu = positionMenu
        menu.addItem(position)

        menu.addItem(.separator())
        for line in [String(localized: "Right Shift (tap) … convert / next candidate / reconvert"),
                     String(localized: "Return … confirm"),
                     String(localized: "Space … confirm and type a space"),
                     String(localized: "Esc … restore the original spelling"),
                     String(localized: "⌘1–⌘5 … confirm that candidate"),
                     String(localized: "⌘D … look the word up in Dictionary")] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit SpellBar"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    /// The menu bar icon.
    /// Drawn as shapes only, since letters take up width. Two bars read as the kanji for "two", so the lower one
    /// is the squiggle that spell checkers underline with.
    private static let statusIcon: NSImage = {
        let size = NSSize(width: 15, height: 13)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // The bar standing for a word
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 8.0, width: 12, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()

            // The spell checker squiggle
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
        image.isTemplate = true          // follows the menu bar's light or dark appearance
        return image
    }()

    private func applyStatusIcon() {
        guard let button = statusItem.button else { return }
        button.image = AppDelegate.statusIcon
        button.title = ""
        button.appearsDisabled = !engine.enabled
    }

    /// The status line is read when the menu opens, so it describes the moment the user looked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        switch engine.status {
        case .listening:
            statusLine.title = String(localized: "Status: listening")
        case .turnedOff:
            statusLine.title = String(localized: "Status: turned off in this menu")
        case .needsPermission:
            statusLine.title = String(localized: "Status: needs Accessibility and Input Monitoring")
        case .monitorOff:
            statusLine.title = String(localized: "Status: paused, macOS turned the keyboard monitor off")
        case .secureInput(let holder?):
            statusLine.title = String(format: String(localized: "Status: paused, secure input is on (held by %@)"), holder)
        case .secureInput(nil):
            statusLine.title = String(localized: "Status: paused, secure input is on")
        case .kana:
            statusLine.title = String(localized: "Status: paused while the Japanese input is typing kana")
        }
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

    /// Registers or removes the login item through `SMAppService` (macOS 13 and later).
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
            a.messageText = String(localized: "Couldn't change the start-at-login setting")
            a.informativeText = error.localizedDescription + "\n\n"
                + String(localized: "You can also add it under System Settings → General → Login Items.")
            a.runModal()
        }
        item.state = service.status == .enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// --selftest: checks the candidate engine, word tracking and reconversion rules without any permission or UI
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

        print("\n--- condensing dictionary entries ---")
        // Raw text as the two kinds of dictionary return it (shortened).
        let pellucid = "pel･lu･cid | pɪlúːsɪd | 形容詞｟文｠ 1 〈目･水･音などが〉澄みきった. 2 〈文体･意味などが〉明瞭な."
        let kerfuffle = "ker･fuf･fle | kərfʌ́f(ə)l | 名詞C｟英･くだけて｠ 〖単数形で〗 «…に関する» から騒ぎ, 大騒ぎ, 騒動 «about, over» ."
        let obsequious = "ob･se･qui･ous | əbsíːkwiəs | 形容詞｟かたく･けなして｠ 【相手に】おもねるような, こびへつらった «to» . ～･ly副詞こびへつらうように."
        let definitionCases: [(String, String, String?)] = [
            ("English: first sense, before the example",
             "defenestrate de·fen·es·trate | dēˈfenəˌstrāt | verb [with object] 1 rare throw (someone) out of a window: she had made up her mind. 2 remove or dismiss (someone) from a position of power.",
             "rare throw (someone) out of a window"),
            ("English: list of paraphrases",
             "receive re·ceive | rəˈsēv | verb [with object] 1 be given, presented with, or paid (something): she received a letter. 2 suffer or experience.",
             "be given, presented with, or paid (something)"),
            ("English: semicolon inside the sense",
             "affect¹ af·fect | əˈfekt | verb [with object] 1 have an effect on; make a difference to: the disease affects the central nervous system.",
             "have an effect on; make a difference to"),
            ("English: noun with (plural …)",
             "dictionary dic·tio·nary | ˈdikSHəˌnerē | noun (plural dictionaries) a book that gives the meaning of words: a Spanish dictionary.",
             "a book that gives the meaning of words"),
            ("English: no sense number, no example",
             "ephemeral | əˈfem(ə)rəl | adjective lasting for a very short time",
             "lasting for a very short time"),
            ("English: auxiliary verb is not read as verb",
             "can² | kan | auxiliary verb (3rd singular present can) be able to",
             "be able to"),
            ("English: long sense is cut at a word",
             "x | x | noun " + String(repeating: "word ", count: 30),
             String(repeating: "word ", count: 16).trimmingCharacters(in: .whitespaces) + "…"),   // 79 characters fit
            ("English: no part of speech, nothing to anchor on", "foo bar baz", nil),
            ("Japanese: adjective, two senses", pellucid, "〈目･水･音などが〉澄みきった. 2 〈文体･意味などが〉明瞭な."),
            ("Japanese: leading note keeps its brackets", kerfuffle, "«…に関する» から騒ぎ, 大騒ぎ, 騒動 «about, over» ."),
            ("Japanese: notes and inflections dropped", obsequious, "【相手に】おもねるような, こびへつらった «to» . ～･ly こびへつらうように."),
        ]
        var definitionFailures = 0
        for (label, raw, expected) in definitionCases {
            let got = Definitions.condense(raw)
            let ok = got == expected
            if !ok { definitionFailures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 46, withPad: " ", startingAt: 0)) -> \(got ?? "nil")"
                  + "\(ok ? "" : "   (expected \(expected ?? "nil"))")")
        }
        print(definitionFailures == 0 ? "all \(definitionCases.count) passed" : "\(definitionFailures) FAILED")

        print("\n--- localization: each language's table is in the bundle ---")
        let localeChecks: [(String, String, String)] = [
            ("en", "Quit SpellBar", "Quit SpellBar"),
            ("ja", "Quit SpellBar", "SpellBar を終了"),
            ("en", "Start at login", "Start at login"),
            ("ja", "Start at login", "ログイン時に自動起動"),
        ]
        var localeFailures = 0
        for (lang, key, expected) in localeChecks {
            let bundle = Bundle.main.path(forResource: lang, ofType: "lproj").flatMap { Bundle(path: $0) }
            let got = bundle?.localizedString(forKey: key, value: "<missing>", table: nil) ?? "<no \(lang).lproj>"
            let ok = got == expected
            if !ok { localeFailures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(lang) \(key.padding(toLength: 16, withPad: " ", startingAt: 0)) -> \(got)")
        }
        print(localeFailures == 0 ? "all \(localeChecks.count) passed" : "\(localeFailures) FAILED")

        print("\n--- which positions an app reports are believed ---")
        // Accessibility coordinates: origin at the top left of the main display.
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        let believed: [(String, Bool, Bool)] = [
            ("caret in a text field",
             CaretLocator.isPlausibleCaret(r(500, 300, 2, 18)), true),
            ("caret at the screen's corner (no real answer)",
             CaretLocator.isPlausibleCaret(r(0, 0, 0, 16)), false),
            ("caret with no height",
             CaretLocator.isPlausibleCaret(r(500, 300, 2, 0)), false),
            ("'caret' as tall as a page of text",
             CaretLocator.isPlausibleCaret(r(500, 300, 600, 800)), false),
            ("caret that is not a number",
             CaretLocator.isPlausibleCaret(r(.nan, 300, 2, 18)), false),
            ("text field of normal size",
             CaretLocator.isPlausibleField(role: "AXTextField", frame: r(100, 200, 300, 24)), true),
            ("search field",
             CaretLocator.isPlausibleField(role: "AXSearchField", frame: r(100, 40, 200, 28)), true),
            ("remote desktop: the whole window",
             CaretLocator.isPlausibleField(role: "AXWindow", frame: r(0, 25, 1512, 957)), false),
            ("remote desktop: a group filling the screen",
             CaretLocator.isPlausibleField(role: "AXGroup", frame: r(0, 0, 1512, 982)), false),
            ("web page that exposes only its web area",
             CaretLocator.isPlausibleField(role: "AXWebArea", frame: r(0, 90, 1440, 800)), false),
            ("a document-sized text area",
             CaretLocator.isPlausibleField(role: "AXTextArea", frame: r(100, 100, 700, 900)), false),
            ("no role at all",
             CaretLocator.isPlausibleField(role: nil, frame: r(100, 200, 300, 24)), false),
        ]
        var believedFailures = 0
        for (label, got, expected) in believed {
            let ok = got == expected
            if !ok { believedFailures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 48, withPad: " ", startingAt: 0)) -> \(got ? "believed" : "refused")")
        }
        print(believedFailures == 0 ? "all \(believed.count) passed" : "\(believedFailures) FAILED")

        print("\n--- settings carried over from the previous bundle identifier ---")
        let oldDomain: [String: Any] = ["didSetUpLoginItem": true, "NSStatusItem Preferred Position Item-0": 794]
        let migrationCases: [(String, [String: Any], [String: Any], Set<String>)] = [
            ("fresh domain gets everything", oldDomain, [:],
             ["didSetUpLoginItem", "NSStatusItem Preferred Position Item-0"]),
            ("a key already set is not overwritten", oldDomain, ["NSStatusItem Preferred Position Item-0": 700],
             ["didSetUpLoginItem"]),
            ("nothing to carry from an empty domain", [:], [:], []),
        ]
        var migrationFailures = 0
        for (label, previous, current, expected) in migrationCases {
            let got = Set(AppDelegate.settingsToCarry(from: previous, into: current).keys)
            let ok = got == expected
            if !ok { migrationFailures += 1 }
            print("\(ok ? "ok  " : "FAIL") \(label.padding(toLength: 40, withPad: " ", startingAt: 0)) -> \(got.sorted())")
        }
        print(migrationFailures == 0 ? "all \(migrationCases.count) passed" : "\(migrationFailures) FAILED")
        // Which language the app itself picks in this run, e.g. with `-AppleLanguages "(ja)"` on the command line.
        print("language chosen for this run: \(Bundle.main.preferredLocalizations.first ?? "?")"
              + " (\(String(localized: "Quit SpellBar")))")

        print("\n--- definitions ---")
        for w in ["receive", "environment", "definitely", "separate", "occurrence", "async"] {
            print(String(format: "%-12@ %@", w as NSString, Definitions.lookup(w) ?? "(not in a dictionary)"))
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
