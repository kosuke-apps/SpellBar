import Cocoa
import OSLog

/// Records rare events that explain later misbehaviour. Never records anything typed.
private let runtimeLog = Logger(subsystem: "local.spellbar", category: "runtime")

/// 候補ウィンドウの描画．
/// 「変換対象の語（下線付き）| 候補1 候補2 …」を上段に，選択中の候補の語義を下段に出す．
///
/// 大きさは常に固定．候補の数や語義の有無で幅も高さも変えない．
/// 内容が変わるたびにチップが動くと目で追えなくなるため，中央寄せもしていない．
final class BarView: NSView {

    var pending: String?                    // 変換対象の語（下線を引いて表示する）
    var items: [String] = []
    var selected: Int?                      // 変換モードでいま当たっている候補
    var definition: String?                 // 選択中の候補の語義
    var debugOverride: String?              // デバッグ表示（語義の代わりに出す）
    var onPick: ((Int) -> Void)?

    private var chipRects: [NSRect] = []
    private var laidOut = false
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private let wordFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private let pendFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private let keyFont  = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private let defFont  = NSFont.systemFont(ofSize: 11, weight: .regular)
    private let chipPadX: CGFloat = 11
    private let gap: CGFloat = 6
    private let edge: CGFloat = 12
    private let keyGap: CGFloat = 6
    private let sepGap: CGFloat = 12

    static let chipRow: CGFloat = 42        // 候補チップの行
    static let defRow: CGFloat = 22         // 語義の行（内容が無くても場所は空けておく）
    static let totalHeight = chipRow + defRow

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func update(pending: String?, items: [String], selected: Int?, definition: String?) {
        self.pending = pending
        self.items = items
        self.selected = selected
        self.definition = definition
        laidOut = false
        needsDisplay = true
    }

    // MARK: レイアウト

    private func keyLabel(_ i: Int) -> String { "⌘\(i + 1)" }
    private func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: f]).width
    }
    private func chipWidth(_ i: Int) -> CGFloat {
        chipPadX + textWidth(keyLabel(i), keyFont) + keyGap + textWidth(items[i], wordFont) + chipPadX
    }
    private var pendingWidth: CGFloat {
        guard let p = pending else { return 0 }
        return textWidth(p, pendFont) + sepGap * 2
    }

    /// 中身を並べるのに必要な幅．左端を固定したまま右へだけ伸ばすのに使う．
    func contentWidth(max limit: CGFloat) -> CGFloat {
        var w = edge + pendingWidth
        for i in items.indices { w += chipWidth(i) + (i == items.count - 1 ? 0 : gap) }
        w += edge
        if let d = debugOverride ?? definition {
            w = Swift.max(w, Swift.min(textWidth(d, defFont) + edge * 2, limit))
        }
        return Swift.min(Swift.max(w, 260), limit)
    }

    /// 幅に収まるぶんだけチップを置く．はみ出す候補は描かない．
    private func layoutChips() {
        chipRects = []
        var x = edge + pendingWidth
        let h = BarView.chipRow - 12
        for i in items.indices {
            let w = chipWidth(i)
            guard x + w <= bounds.width - edge else { break }
            chipRects.append(NSRect(x: x, y: 6, width: w, height: h))
            x += w + gap
        }
        laidOut = true
    }

    // MARK: 描画

    override func draw(_ dirty: NSRect) {
        if !laidOut { layoutChips() }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        let dim = NSColor(white: dark ? 0.60 : 0.48, alpha: 1)

        // 変換対象の語 + 下線（IMEの未確定文字列に相当する表示）
        if let p = pending {
            let s = (p as NSString).size(withAttributes: [.font: pendFont])
            let x = edge, y = BarView.chipRow / 2 - s.height / 2
            (p as NSString).draw(at: NSPoint(x: x, y: y),
                                 withAttributes: [.font: pendFont, .foregroundColor: ink])
            let uy = (y + s.height + 1.5).rounded()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: uy))
            line.line(to: NSPoint(x: x + s.width, y: uy))
            line.lineWidth = 2
            ink.withAlphaComponent(0.75).setStroke()
            line.stroke()

            let sep = NSBezierPath()
            let sx = (edge + pendingWidth - sepGap / 2).rounded()
            sep.move(to: NSPoint(x: sx, y: 9))
            sep.line(to: NSPoint(x: sx, y: BarView.chipRow - 9))
            sep.lineWidth = 1
            NSColor(white: dark ? 0.40 : 0.78, alpha: 1).setStroke()
            sep.stroke()
        }

        for (i, r) in chipRects.enumerated() {
            let isSel = (selected == i)
            let isHot = (hovered == i)
            let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)

            if isSel {
                NSColor.controlAccentColor.setFill(); path.fill()
            } else {
                (dark ? NSColor(white: isHot ? 0.32 : 0.20, alpha: 1)
                      : NSColor(white: isHot ? 0.88 : 1.00, alpha: 1)).setFill()
                path.fill()
                NSColor(white: dark ? 0.42 : 0.80, alpha: 1).setStroke()
                path.lineWidth = 1; path.stroke()
            }

            let key = keyLabel(i) as NSString
            let word = items[i] as NSString
            let ks = key.size(withAttributes: [.font: keyFont])
            let ws = word.size(withAttributes: [.font: wordFont])

            key.draw(at: NSPoint(x: r.minX + chipPadX, y: r.midY - ks.height / 2),
                     withAttributes: [.font: keyFont,
                                      .foregroundColor: isSel ? NSColor.white.withAlphaComponent(0.75) : dim])
            word.draw(at: NSPoint(x: r.minX + chipPadX + ks.width + keyGap, y: r.midY - ws.height / 2),
                      withAttributes: [.font: wordFont, .foregroundColor: isSel ? NSColor.white : ink])
        }

        drawDefinition(dark: dark)
    }

    private func drawDefinition(dark: Bool) {
        guard let d = debugOverride ?? definition else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let rect = NSRect(x: edge, y: BarView.chipRow - 3,
                          width: bounds.width - edge * 2, height: BarView.defRow)
        (d as NSString).draw(in: rect, withAttributes: [
            .font: defFont,
            .foregroundColor: NSColor(white: dark ? 0.66 : 0.42, alpha: 1),
            .paragraphStyle: style,
        ])
    }

    // MARK: マウス

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseMoved(with e: NSEvent) {
        hovered = chipRects.firstIndex { $0.contains(convert(e.locationInWindow, from: nil)) }
    }
    override func mouseExited(with e: NSEvent) { hovered = nil }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = chipRects.firstIndex(where: { $0.contains(p) }) { onPick?(i) }
    }
}

/// 候補ウィンドウを載せるフローティングパネル．
/// フォーカスを奪わない (.nonactivatingPanel) のが肝．奪うと入力中のアプリからカーソルが外れる．
final class CandidateBar {

    /// 候補ウィンドウを画面のどこに出すか．
    /// 既定は日本語IMEの候補ウィンドウと同じく，入力位置のすぐ下（入らなければ上）．
    enum Placement: Int { case followCaret, bottom, top }

    /// Show on every Space (desktop), including full-screen ones.
    private static let spacesBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    private var panel: NSPanel
    private let blur = NSVisualEffectView()
    private let view = BarView()
    private(set) var isVisible = false
    /// Set when the screen layout or the placement mode changes, so the next show re-places the panel.
    private var needsPlacement = true
    private var placedAtTop = false
    private var anchor = NSPoint.zero
    private var anchorLimit: CGFloat = 760
    private var fixedWidth: CGFloat?
    private var lastRebuild = Date.distantPast

    private let maxWidth: CGFloat = 760
    private let sideMargin: CGFloat = 80
    private let edgeGap: CGFloat = 14
    /// キャレットと候補ウィンドウのあいだに空ける隙間
    private let caretGap: CGFloat = 6
    private(set) var lastNote = ""
    var debug = false

    var placement: Placement = .followCaret {
        didSet { needsPlacement = true }
    }

    init(onPick: @escaping (Int) -> Void) {
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 11
        blur.layer?.masksToBounds = true
        blur.addSubview(view)

        panel = CandidateBar.makePanel()
        panel.contentView = blur
        view.onPick = onPick

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.needsPlacement = true }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.needsPlacement = true }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: BarView.totalHeight),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = spacesBehavior
        return panel
    }

    /// Registers the panel on every Space again.
    ///
    /// When SpellBar starts as a login item, the window server can take the panel before Spaces are ready and
    /// pin it to the first desktop; it then never appears on the others. Clearing and setting the behavior
    /// re-registers it. The panel is hidden when this runs, so nothing flickers.
    private func joinAllSpaces() {
        panel.collectionBehavior = []
        panel.collectionBehavior = CandidateBar.spacesBehavior
    }

    /// 位置を決めるのは「単語を打ち始めたとき」と「画面が変わったとき」だけ．
    /// 打っている最中に動くと目で追えなくなるので，同じ単語のあいだは固定する．
    private func place() {
        var screen = NSScreen.main ?? NSScreen.screens[0]
        var hit: CaretLocator.Hit?

        if placement == .followCaret {
            hit = CaretLocator.caret()
            // A caret rect that lies on no screen is garbage; placing by it would push the panel off-screen.
            if let r = hit?.rect, let s = NSScreen.screens.first(where: { $0.frame.intersects(r) }) {
                screen = s
            } else if hit != nil {
                hit = nil
                CaretLocator.note("caret reported outside every screen")
            }
        }

        let vf = screen.visibleFrame
        needsPlacement = false
        let w = min(maxWidth, vf.width - sideMargin * 2)
        let bottomY = vf.minY + edgeGap
        let topY = vf.maxY - BarView.totalHeight - edgeGap
        var x = (vf.midX - w / 2).rounded()
        var y = bottomY

        switch placement {
        case .bottom:
            lastNote = "常に画面の下"
        case .top:
            y = topY
            lastNote = "常に画面の上"
        case .followCaret:
            if let caret = hit?.rect {
                // 横はキャレットの少し左に合わせる．画面外へはみ出さないよう押し込む．
                x = min(max(caret.minX - 24, vf.minX + 8), vf.maxX - w - 8).rounded()
                // 縦は原則キャレットの下．入らなければ上に出す．
                let below = caret.minY - BarView.totalHeight - caretGap
                let above = caret.maxY + caretGap
                y = below >= vf.minY + 8 ? below : above
                y = min(max(y, vf.minY + 8), topY)          // never leave the visible area
                lastNote = String(format: "%@ x%.0f y%.0f (%@)",
                                  hit!.source, caret.minX, caret.minY, CaretLocator.lastNote)
            } else {
                lastNote = CaretLocator.lastNote
            }
        }

        placedAtTop = y > vf.midY
        anchor = NSPoint(x: x, y: y.rounded())
        // 追従中は左端をキャレットに合わせ，幅は内容に応じて右へ伸ばす．
        // 固定配置のときは従来どおり中央に固定幅で置く．
        anchorLimit = placement == .followCaret ? vf.maxX - 8 - x : w
        fixedWidth = placement == .followCaret ? nil : w
    }

    /// 左端（アンカー）は動かさず，幅だけ中身に合わせ直す．
    private func resizeToContent() {
        let width = (fixedWidth ?? view.contentWidth(max: anchorLimit)).rounded()
        let frame = NSRect(x: anchor.x, y: anchor.y, width: width, height: BarView.totalHeight)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
    }

    func show(pending: String?, candidates: [String], selected: Int?, definition: String? = nil) {
        guard pending != nil || !candidates.isEmpty else { hide(); return }
        if !isVisible {
            joinAllSpaces()
            place()
        } else if needsPlacement {
            place()
        }
        view.debugOverride = debug ? "［位置］\(lastNote)" : nil
        view.update(pending: pending, items: candidates, selected: selected, definition: definition)
        resizeToContent()
        panel.orderFrontRegardless()
        ensureOnActiveSpace()
        isVisible = true
    }

    /// A window registered on every Space is by definition on the active one. When it is not, the window
    /// server has dropped that registration, which happens across sleep, and the panel stays on one desktop.
    /// Registering again normally brings it back; if it does not, the panel is replaced.
    private func ensureOnActiveSpace() {
        guard !panel.isOnActiveSpace else { return }

        joinAllSpaces()
        panel.orderFrontRegardless()
        if panel.isOnActiveSpace {
            runtimeLog.notice("candidate window had left the active Space; registered again")
            return
        }

        // Rebuilding is the last resort, and rate-limited: a window server that keeps saying no would
        // otherwise have the panel replaced on every word.
        guard Date().timeIntervalSince(lastRebuild) > 60 else { return }
        lastRebuild = Date()
        let old = panel
        panel = CandidateBar.makePanel()
        panel.setFrame(old.frame, display: false)
        panel.contentView = blur          // moves the view over, leaving the old panel empty
        old.orderOut(nil)
        panel.orderFrontRegardless()
        runtimeLog.notice("candidate window recreated: registering again did not bring it back")
    }

    func hide() {
        guard isVisible else { return }
        panel.orderOut(nil)
        view.update(pending: nil, items: [], selected: nil, definition: nil)
        isVisible = false
    }
}
