import Foundation

/// Follows the word behind the caret from keystrokes alone.
///
/// Kept free of events and UI so that key sequences can be replayed in the self-test.
struct WordTracker {

    /// A finished word the caret is still right behind: "receive" followed by at most a few separators.
    /// While it lasts, the conversion key converts it again and Backspace steps back into it.
    struct Finished: Equatable {
        var word: String
        var suffix: String
    }

    /// The word being typed, not yet converted.
    private(set) var typing = ""
    /// The word just finished, while the caret stays right behind it.
    private(set) var finished: Finished?

    /// At most this many separators may follow a finished word before it is forgotten.
    static let maxSuffix = TextContext.maxSuffix

    /// What the conversion key acts on: the word being typed, else the finished word.
    var target: Finished? {
        if !typing.isEmpty { return typing.count >= 2 ? Finished(word: typing, suffix: "") : nil }
        if let f = finished, f.word.count >= 2 { return f }
        return nil
    }

    mutating func letter(_ c: Character) {
        if typing.isEmpty, let f = finished {
            // Straight after a finished word the word goes on; after a separator a new one starts.
            typing = f.suffix.isEmpty ? f.word : ""
            finished = nil
        }
        typing.append(c)
    }

    /// A space or punctuation. Returns false when the word is lost (too many separators).
    mutating func separator(_ c: Character) -> Bool {
        if !typing.isEmpty {
            finished = Finished(word: typing, suffix: String(c))
            typing = ""
            return true
        }
        guard var f = finished, f.suffix.count < Self.maxSuffix else { reset(); return false }
        f.suffix.append(c)
        finished = f
        return true
    }

    /// Returns false when there was nothing to step back into.
    mutating func backspace() -> Bool {
        if !typing.isEmpty {
            typing.removeLast()
            return true
        }
        guard var f = finished else { reset(); return false }
        if f.suffix.isEmpty {
            typing = String(f.word.dropLast())
            finished = nil
        } else {
            f.suffix.removeLast()
            if f.suffix.isEmpty {
                typing = f.word
                finished = nil
            } else {
                finished = f
            }
        }
        return true
    }

    /// SpellBar put `word` (and `suffix`) in place; the caret is right behind them.
    mutating func placed(_ word: String, suffix: String = "") {
        typing = ""
        finished = Finished(word: word, suffix: suffix)
    }

    /// A separator SpellBar typed itself after the finished word.
    mutating func appendToSuffix(_ c: Character) {
        finished?.suffix.append(c)
    }

    /// Makes `word` the word being typed again.
    mutating func resume(_ word: String) {
        typing = word
        finished = nil
    }

    mutating func reset() {
        typing = ""
        finished = nil
    }
}

/// What the conversion key converts.
enum ConversionTarget: Equatable {
    /// The word followed from keystrokes.
    case tracked(WordTracker.Finished)
    /// The word read from the app's text around the caret.
    case atCaret(TextContext.Word)

    /// Chooses between the word followed from keystrokes and the app's actual text.
    ///
    /// The app's text is the truth: it may have changed behind SpellBar's back (two spaces turned into ". ",
    /// autocorrect, text replacement), so words joined by deleting separators are only visible there. But some
    /// apps report their text a moment late, and trusting a stale reading would delete the wrong number of
    /// characters. So the reading is used only when it agrees with the keystrokes on where the word ends: the
    /// caret right behind the word and the same number of separators, with the tracked word at its end or the
    /// same length (an autocorrected word).
    static func choose(tracked: WordTracker.Finished?, actual: TextContext.Word?) -> ConversionTarget? {
        guard let tracked else { return actual.map { .atCaret($0) } }
        guard let actual else { return .tracked(tracked) }
        let sameEnd = actual.caretToWordEnd == 0 && !actual.selected
            && actual.suffix.count == tracked.suffix.count
        let sameWord = actual.text.hasSuffix(tracked.word) || actual.text.count == tracked.word.count
        return sameEnd && sameWord ? .atCaret(actual) : .tracked(tracked)
    }
}
