import Cocoa
import ApplicationServices

/// Reads the text around the caret of the focused input to find the word to convert again.
///
/// This is what makes reconversion work after the caret has moved: the user clicks into or right behind a word,
/// or selects it, and presses the conversion key. Apps that do not expose their text through the accessibility
/// API return nil; the caller then gives up.
enum TextContext {

    struct Word {
        let text: String
        /// Separators between the end of the word and the caret, such as a space or a comma.
        let suffix: String
        /// How many characters the caret must move right to reach the end of the word.
        let caretToWordEnd: Int
        /// The word was selected; the selection must be collapsed to its end before replacing.
        let selected: Bool
    }

    /// Characters read on each side of the caret. Words are far shorter; this keeps big documents cheap.
    private static let reach = 64
    /// At most this many separators may sit between the word and the caret ("word, |" still finds "word").
    static let maxSuffix = 3

    static func wordAtCaret() -> Word? {
        guard let element = CaretLocator.focusedElement(),
              let range = CaretLocator.selectedRange(of: element) else { return nil }

        if range.length > 0 {
            guard let text = string(of: element, location: range.location, length: range.length),
                  text.count >= 2, text.allSatisfy(isWordCharacter) else { return nil }
            return Word(text: text, suffix: "", caretToWordEnd: 0, selected: true)
        }

        let start = max(range.location - reach, 0)
        guard let around = string(of: element, location: start, length: range.location - start + reach) else {
            return nil
        }
        return word(in: around as NSString, caret: range.location - start)
    }

    /// Finds the word touching the caret, or the word right before a few separators.
    static func word(in text: NSString, caret: Int) -> Word? {
        guard caret >= 0, caret <= text.length else { return nil }
        func wordChar(_ i: Int) -> Bool { i >= 0 && i < text.length && isWordUnit(text.character(at: i)) }
        func separator(_ i: Int) -> Bool { i >= 0 && i < text.length && isSeparatorUnit(text.character(at: i)) }

        var end = caret
        while wordChar(end) { end += 1 }

        if end > caret || wordChar(caret - 1) {
            // The caret is inside the word or at one of its edges.
            var left = caret
            while wordChar(left - 1) { left -= 1 }
            let found = text.substring(with: NSRange(location: left, length: end - left))
            guard found.count >= 2 else { return nil }
            return Word(text: found, suffix: "", caretToWordEnd: end - caret, selected: false)
        }

        // The caret sits after separators: step back over them to the word.
        var wordEnd = caret
        while wordEnd > 0, caret - wordEnd < maxSuffix, separator(wordEnd - 1) { wordEnd -= 1 }
        guard wordEnd < caret, wordChar(wordEnd - 1) else { return nil }
        var left = wordEnd
        while wordChar(left - 1) { left -= 1 }
        let found = text.substring(with: NSRange(location: left, length: wordEnd - left))
        guard found.count >= 2 else { return nil }
        return Word(text: found,
                    suffix: text.substring(with: NSRange(location: wordEnd, length: caret - wordEnd)),
                    caretToWordEnd: 0, selected: false)
    }

    // MARK: Characters

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c == "'" || c == "\u{2019}"
    }

    /// A separator that keeps the caret on the same line: a space or punctuation, never a line break.
    static func isInlineSeparator(_ c: Character) -> Bool {
        c == " " || (c.isPunctuation && !isWordCharacter(c))
    }

    private static func isWordUnit(_ u: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return isWordCharacter(Character(scalar))
    }

    private static func isSeparatorUnit(_ u: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return isInlineSeparator(Character(scalar))
    }

    // MARK: Reading text

    /// A slice of the input's text. Prefers asking for just the range; falls back to the whole value.
    private static func string(of element: AXUIElement, location: Int, length: Int) -> String? {
        var query = CFRange(location: location, length: length)
        if let total = CaretLocator.copy(element, kAXNumberOfCharactersAttribute) as? Int {
            query.length = max(min(query.length, total - query.location), 0)
        }
        if let param = AXValueCreate(.cfRange, &query) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success,
               let text = out as? String {
                return text
            }
        }
        guard let whole = CaretLocator.copy(element, kAXValueAttribute) as? String else { return nil }
        let ns = whole as NSString
        let from = min(location, ns.length)
        return ns.substring(with: NSRange(location: from, length: min(length, ns.length - from)))
    }
}
