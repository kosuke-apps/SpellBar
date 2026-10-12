import Cocoa
import ApplicationServices

/// Returns the caret position of the focused text input in screen coordinates (origin at the bottom left).
///
/// It asks another process through the accessibility API, so a short timeout keeps an unresponsive app
/// from freezing SpellBar. Many apps do not support it, so where a lookup failed is kept in `lastNote`.
enum CaretLocator {

    struct Hit {
        let rect: CGRect
        let source: String      // "caret" or "input field"
    }

    private static let timeout: Float = 0.08
    /// The outcome of the last lookup, for the debug readout that tells apps where following the caret fails.
    private(set) static var lastNote = String(localized: "Not read yet")

    /// Lets callers record why they rejected a result, for the debug readout.
    static func note(_ text: String) { lastNote = text }

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

    static func caret() -> Hit? {
        guard let element = focusedElement() else {
            lastNote = String(localized: "Couldn't get the focused element")
            return nil
        }

        if let rect = caretBounds(of: element), rect.height > 0 {
            lastNote = String(localized: "From the caret")
            return Hit(rect: flip(rect), source: String(localized: "caret"))
        }
        if let rect = elementBounds(of: element), rect.height > 0 {
            lastNote = String(localized: "From the input field's rectangle (caret not supported)")
            return Hit(rect: flip(rect), source: String(localized: "input field"))
        }
        lastNote = String(localized: "This app doesn't report a position")
        return nil
    }

    /// The rectangle of the selection (the caret). It is the most accurate thing to get.
    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        guard let range = selectedRange(of: element) else { return nil }

        // Some apps return no rectangle for a zero-length range, so ask for at least one character.
        // With the caret at the start of a line, also try the character before it.
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

    /// When the caret cannot be had, the rectangle of the input field itself stands in.
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

    /// The accessibility API puts the origin at the top left of the main display with y pointing down.
    /// AppKit's origin is the bottom left, so flip it. The main display is the screen whose origin is (0,0).
    private static func flip(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let height = primary?.frame.height ?? 0
        return CGRect(x: rect.origin.x, y: height - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }
}
