import Cocoa
import ApplicationServices

/// Finds the caret position of the focused text input.
///
/// It asks another process through the accessibility API, which can be slow or never answer, so it must only run
/// on `CaretLocator.queue`, never on the main thread: a main thread waiting on another app is a main thread that
/// cannot run the event tap, and every key typed anywhere stalls with it.
///
/// Many apps give no usable answer: remote desktop and virtual machine windows, canvas-drawn editors, web pages
/// whose accessibility is off. A wrong answer is worse than none, because it puts the candidate window in a
/// place that has nothing to do with the caret, so every answer is checked and refused when it is not plausible.
enum CaretLocator {

    struct Hit {
        /// In accessibility coordinates: origin at the top left of the main display, y pointing down.
        /// Convert it with `toScreenCoordinates` on the main thread.
        let rect: CGRect
        let source: String      // "caret" or "input field"
    }

    /// The outcome of one lookup, with a line saying how it came about for the debug readout.
    struct Lookup {
        let hit: Hit?
        let note: String
    }

    /// Where lookups run. One queue, so a stuck app delays only the next lookup, not typing.
    static let queue = DispatchQueue(label: "spellbar.caret", qos: .userInteractive)

    private static let timeout: Float = 0.05
    /// All the lookups of one word must fit in this, however many attributes are asked for.
    private static let budget: TimeInterval = 0.12

    /// Roles of the elements people type into. Anything else (a window, a table, a web area) is not an input,
    /// however it is sized.
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// A caret is about one line high; taller means the range was a whole block of text.
    private static let maxCaretHeight: CGFloat = 120
    /// An input field this tall is a document, not a place to hang a candidate window under.
    private static let maxFieldHeight: CGFloat = 300

    // MARK: Plausibility (pure, so the self-test can run it)

    /// A caret rectangle in accessibility coordinates (origin top left) that can be believed.
    static func isPlausibleCaret(_ r: CGRect) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return false }
        guard r.width >= 0, r.height > 0, r.height <= maxCaretHeight else { return false }
        // Apps with no real answer often return a rectangle at the screen's corner.
        return !(r.origin.x == 0 && r.origin.y == 0)
    }

    /// The frame of an element that can stand in for the caret.
    static func isPlausibleField(role: String?, frame r: CGRect) -> Bool {
        guard let role, textRoles.contains(role) else { return false }
        return r.width > 0 && r.height > 0 && r.height <= maxFieldHeight && !(r.origin.x == 0 && r.origin.y == 0)
    }

    // MARK: Lookups

    /// The focused text input of the frontmost app, with a short messaging timeout applied.
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let focused = copy(system, kAXFocusedUIElementAttribute) else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// The caret (or selection) of a text input, in UTF-16 units.
    static func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Call this on `queue`.
    static func caret() -> Lookup {
        let start = Date()
        func overBudget() -> Bool { Date().timeIntervalSince(start) > budget }

        guard let element = focusedElement() else {
            return Lookup(hit: nil, note: String(localized: "Couldn't get the focused element"))
        }
        let role = copy(element, kAXRoleAttribute) as? String

        if !overBudget(), let rect = caretBounds(of: element, until: { overBudget() }), isPlausibleCaret(rect) {
            return Lookup(hit: Hit(rect: rect, source: String(localized: "caret")),
                          note: String(localized: "From the caret"))
        }
        if !overBudget(), let rect = elementBounds(of: element), isPlausibleField(role: role, frame: rect) {
            return Lookup(hit: Hit(rect: rect, source: String(localized: "input field")),
                          note: String(localized: "From the input field's rectangle (caret not supported)"))
        }

        // Say what the app did give, which is what tells one kind of app from another.
        let detail = [role ?? "?", elementBounds(of: element).map { "\(Int($0.width))×\(Int($0.height))" }]
            .compactMap { $0 }.joined(separator: " ")
        return Lookup(hit: nil,
                      note: String(format: String(localized: "This app doesn't report a usable position (%@)"), detail))
    }

    /// The rectangle of the selection (the caret). It is the most accurate thing to get.
    private static func caretBounds(of element: AXUIElement, until stop: () -> Bool) -> CGRect? {
        guard let range = selectedRange(of: element) else { return nil }

        // Some apps return no rectangle for a zero-length range, so ask for at least one character.
        // With the caret at the start of a line, also try the character before it.
        for query in [CFRange(location: range.location, length: max(range.length, 1)),
                      CFRange(location: max(range.location - 1, 0), length: 1)] {
            if stop() { return nil }
            var q = query
            guard let param = AXValueCreate(.cfRange, &q) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
                  let value = out else { continue }
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect), isPlausibleCaret(rect) { return rect }
        }
        return nil
    }

    /// The frame of the input field itself.
    private static func elementBounds(of element: AXUIElement) -> CGRect? {
        guard let posValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    /// AppKit's origin is the bottom left, so flip an accessibility rectangle. The main display is the screen
    /// whose origin is (0,0). Call this on the main thread, where `NSScreen` may be read.
    static func toScreenCoordinates(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let height = primary?.frame.height ?? 0
        return CGRect(x: rect.origin.x, y: height - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }
}
