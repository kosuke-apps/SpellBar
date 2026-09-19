import Cocoa
import Carbon

/// Watches the keyboard and brings the Japanese IME's "conversion" to English typing.
///
/// A CGEventTap sees keys before any app does, so this works in apps that do not use AppKit text views
/// (VS Code, Chrome, terminals). The tap callback runs on the main run loop and must stay cheap: candidate
/// lookups run on `CandidateEngine.queue` and accessibility queries on `Engine.axQueue`.
///
/// Interaction, modelled on the Japanese IME:
///   type → tap right Shift to convert → tap again for the next candidate → Return/Space to confirm → Esc to undo
/// Tapping right Shift with no word in progress converts the word behind the caret again.
final class Engine {

    private let candidates = CandidateEngine()
    private var bar: CandidateBar!
    private var tap: CFMachPort?
    private static let axQueue = DispatchQueue(label: "spellbar.accessibility")

    // MARK: State

    /// The word behind the caret, followed from keystrokes.
    private var words = WordTracker()
    /// The conversion in progress, if any.
    private var conv: Conversion?
    /// Bumped on every keystroke, so late async results for an older state are dropped.
    private var generation = 0
    /// Marks events SpellBar injects itself, so the tap ignores them.
    private let injectMark: Int64 = 0x5350_4C42  // "SPLB"
    private var kanaMode = false
    /// Drops definition lookups that finish after the selection moved on.
    private var defToken = 0

    /// Show candidates while typing, without waiting for the conversion key.
    var alwaysShow = true { didSet { if !alwaysShow && conv == nil { bar.hide() } } }
    var enabled = true { didSet { if !enabled { reset() } } }

    var placement: CandidateBar.Placement {
        get { bar.placement }
        set { bar.placement = newValue }
    }

    /// Shows the placement diagnosis in the candidate window, to find apps where following the caret fails.
    var debugPlacement: Bool {
        get { bar.debug }
        set { bar.debug = newValue }
    }

    private struct Conversion {
        let original: String        // the spelling before conversion
        var list: [String]          // candidates; the original is appended so cycling can return to it
        var index: Int              // the candidate currently placed
        var placed: String          // the text actually in the app right now
        /// Separators typed after the word before it was converted again ("word, " keeps its ", ").
        let suffix: String
    }

    // Detecting a solo tap of right Shift
    private var rShiftDownAt: CFAbsoluteTime?
    private var keyPressedWhileShift = false
    private let soloTapLimit: CFAbsoluteTime = 0.4
    private static let rightShiftKeycode: Int64 = 60
    private static let rightShiftFlagBit: UInt64 = 0x0004   // NX_DEVICERSHIFTKEYMASK

    private let digitKeycodes: [Int64] = [18, 19, 20, 21, 23]  // 1, 2, 3, 4, 5
    private static let rightArrow: CGKeyCode = 124

    init() {
        bar = CandidateBar { [weak self] i in self?.confirm(index: i) }
        observeInputSource()
        observeAppSwitch()
    }

    // MARK: - Start

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

    // MARK: - Event handling (main thread; keep it cheap)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard enabled else { return pass }
        if event.getIntegerValueField(.eventSourceUserData) == injectMark { return pass }

        if type == .leftMouseDown { keyPressedWhileShift = true; reset(); return pass }

        // Stay out of password fields and other secure input entirely.
        if IsSecureEventInputEnabled() { reset(); return pass }
        // While the Japanese IME composes kana, its own candidates take over.
        if kanaMode { reset(); return pass }

        if type == .flagsChanged { return handleFlags(event: event) == .swallow ? nil : pass }
        guard type == .keyDown else { return pass }
        return handleKeyDown(event: event) == .swallow ? nil : pass
    }

    /// Whether the app receives the key or SpellBar consumes it.
    private enum Disposition { case pass, swallow }

    /// A solo tap of right Shift (pressed and released with no other key in between) is the conversion key.
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
        return .pass   // Shift itself always reaches the app
    }

    private func handleKeyDown(event: CGEvent) -> Disposition {
        keyPressedWhileShift = true

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)

        // Shortcuts are taken only while the candidate window is on screen; otherwise they belong to the app.
        if cmd, bar.isVisible {
            if keycode == 2, let word = focusedWord() {                  // ⌘D: look the word up
                openInDictionary(word)
                return .swallow
            }
            let count = conv?.list.count ?? barItems.count
            if let idx = digitKeycodes.firstIndex(of: keycode), idx < count {   // ⌘1–⌘5: pick directly
                DispatchQueue.main.async { [weak self] in self?.confirm(index: idx) }
                return .swallow
            }
        }

        if let active = conv {
            switch keycode {
            case 36, 76:  confirm(index: active.index);                  return .swallow  // Return: confirm
            case 49:      confirm(index: active.index, thenSpace: true);  return .swallow  // Space: confirm + space
            case 53:      cancelConversion();                            return .swallow  // Esc: restore
            case 125, 48: cycle(+1);                                     return .swallow  // ↓ / Tab: next
            case 126:     cycle(-1);                                     return .swallow  // ↑: previous
            default:
                // Any other key confirms the current candidate and is then handled as ordinary typing,
                // so a letter continues the word ("receive" + "d") and punctuation ends it.
                finishConversion()
            }
        }

        if ctrl || cmd { reset(); return .pass }

        switch keycode {
        case 53:                                  // Esc
            reset(); return .pass
        case 51:                                  // Backspace
            backspace(); return .pass
        case 36, 76, 48, 123...126, 115, 116, 119, 121:
            // Return, Tab, arrows, Home/End/Page Up/Page Down: the caret leaves the word.
            reset(); return .pass
        default:
            break
        }

        let ns = NSEvent(cgEvent: event)
        guard let c = (ns?.characters ?? ns?.charactersIgnoringModifiers)?.first else { reset(); return .pass }

        if TextContext.isWordCharacter(c) {
            words.letter(c)
            refreshAlwaysShow()
        } else if TextContext.isInlineSeparator(c) {
            let wasTyping = !words.typing.isEmpty
            if !words.separator(c) { reset() } else if wasTyping { endWord() }
        } else {
            reset()
        }
        return .pass
    }

    /// Backspace shortens the word being typed. Past its start it steps back over the separators into the
    /// previous word, which becomes the word being typed again.
    private func backspace() {
        guard words.backspace() else { reset(); return }
        refreshAlwaysShow()
    }

    // MARK: - Conversion

    /// Right Shift tapped. Converts the word behind the caret: the one being typed, the one just finished, or
    /// the one the caret was moved to. During a conversion it moves to the next candidate.
    ///
    /// The app's text is read first, off the main thread because the app may answer slowly; see
    /// `ConversionTarget.choose` for when it wins over the word followed from keystrokes.
    private func convertKeyPressed() {
        if conv != nil { cycle(+1); return }
        let tracked = words.target
        generation &+= 1
        let gen = generation
        Engine.axQueue.async { [weak self] in
            let actual = TextContext.wordAtCaret()
            DispatchQueue.main.async {
                guard let self, gen == self.generation, self.conv == nil else { return }
                switch ConversionTarget.choose(tracked: tracked, actual: actual) {
                case .tracked(let word)?:
                    self.beginConversion(of: word.word, suffix: word.suffix)
                case .atCaret(let word)?:
                    // Move the caret to the end of the word so the usual backspace-and-retype replacement
                    // applies. A right arrow collapses a selection to its end.
                    let moves = word.caretToWordEnd + (word.selected ? 1 : 0)
                    for _ in 0..<moves { Injector.tap(virtualKey: Engine.rightArrow, mark: self.injectMark) }
                    self.beginConversion(of: word.text, suffix: word.suffix)
                case nil:
                    NSSound.beep()
                }
            }
        }
    }

    private func beginConversion(of word: String, suffix: String) {
        generation &+= 1
        let gen = generation
        CandidateEngine.queue.async { [weak self] in
            guard let self else { return }
            let list = self.candidates.candidates(for: word)
            DispatchQueue.main.async {
                guard gen == self.generation, self.conv == nil else { return }
                guard !list.isEmpty else { NSSound.beep(); return }
                self.words.reset()
                self.conv = Conversion(original: word, list: list + [word], index: 0, placed: word, suffix: suffix)
                self.apply(index: 0)
            }
        }
    }

    private func cycle(_ delta: Int) {
        guard let c = conv else { return }
        let n = c.list.count
        apply(index: ((c.index + delta) % n + n) % n)
    }

    /// Writes candidate `index` into the app and updates the candidate window.
    private func apply(index: Int) {
        guard var c = conv, index < c.list.count else { return }
        let next = c.list[index]
        if next != c.placed {
            Injector.replace(deleting: c.placed.count + c.suffix.count, with: next + c.suffix, mark: injectMark)
            c.placed = next
        }
        c.index = index
        conv = c
        bar.show(pending: c.original, candidates: c.list, selected: index)
        lookupDefinition(for: next, at: index)
    }

    /// Looks up the selected candidate in the dictionary and shows the meaning on the second row,
    /// so the user can check it is the word they meant.
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
            guard index < c.list.count else { return }
            apply(index: index)
            learn(typed: c.original, chosen: c.list[index])
            finishConversion()
        } else {
            // Picked straight from the always-on candidates.
            guard index < barItems.count else { return }
            let word = barItems[index]
            learn(typed: words.typing, chosen: word)
            Injector.replace(deleting: words.typing.count, with: word, mark: injectMark)
            words.placed(word)
            endWord()
        }
        if thenSpace {
            Injector.tap(virtualKey: 49, mark: injectMark)
            words.appendToSuffix(" ")
        }
    }

    /// The word the user is looking at: the selected candidate, else the first candidate, else the typed word.
    private func focusedWord() -> String? {
        if let c = conv { return c.list[c.index] }
        if let first = barItems.first { return first }
        return words.typing.isEmpty ? nil : words.typing
    }

    private func openInDictionary(_ word: String) {
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "dict://" + encoded) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Remembers the choice, so the same misspelling offers it first next time.
    private func learn(typed: String, chosen: String) {
        guard !typed.isEmpty, typed != chosen else { return }
        CandidateEngine.queue.async { [weak self] in
            self?.candidates.learning.record(typed: typed, chosen: chosen)
        }
    }

    /// Esc during a conversion: put the original spelling back.
    private func cancelConversion() {
        guard let c = conv else { return }
        if c.placed != c.original {
            Injector.replace(deleting: c.placed.count + c.suffix.count, with: c.original + c.suffix,
                             mark: injectMark)
        }
        conv = nil
        bar.hide()
        if c.suffix.isEmpty { words.resume(c.original) } else { words.placed(c.original, suffix: c.suffix) }
    }

    /// Ends the conversion with the current candidate in place. The caret stays right behind it,
    /// so the word can still be converted again or backspaced into.
    private func finishConversion() {
        guard let c = conv else { return }
        conv = nil
        bar.hide()
        words.placed(c.placed, suffix: c.suffix)
    }

    // MARK: - Always-on candidates

    private var barItems: [String] = []
    private var shownDefinition: String?

    private func refreshAlwaysShow() {
        generation &+= 1
        guard alwaysShow else { barItems = []; bar.hide(); return }
        let gen = generation
        let word = words.typing
        guard !word.isEmpty else { barItems = []; bar.hide(); return }

        // Show the window from the first letter and keep it while there are no candidates.
        // Until new candidates arrive, the previous ones stay (clearing them on every key would flicker).
        // Deferred out of the tap callback: showing the window may query the app for the caret position.
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.generation, self.conv == nil else { return }
            self.bar.show(pending: word, candidates: self.barItems, selected: nil, definition: self.shownDefinition)
        }
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

    /// The word being typed ended (the tracker keeps it as the finished word); clear its candidates.
    private func endWord() {
        barItems = []
        shownDefinition = nil
        generation &+= 1
        bar.hide()
    }

    /// Forgets everything: the caret has moved somewhere SpellBar cannot follow.
    private func reset() {
        conv = nil
        words.reset()
        barItems = []
        shownDefinition = nil
        generation &+= 1
        bar.hide()
    }

    // MARK: - Observers

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
        // e.g. com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese (kana) / ….Roman (alphanumeric)
        kanaMode = id.hasSuffix(".Japanese") || id.contains("Hiragana") || id.contains("Katakana")
    }

    private func observeAppSwitch() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reset() }
    }
}

/// Deletes typed characters and types the chosen candidate in their place.
enum Injector {
    static func replace(deleting count: Int, with word: String, mark: Int64) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = mark
        for _ in 0..<count { post(source, virtualKey: 51, mark: mark); usleep(1200) }   // Backspace
        // Some apps drop characters when too many arrive in one event, so send small chunks.
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
        usleep(1200)
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
