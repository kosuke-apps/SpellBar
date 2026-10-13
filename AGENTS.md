# SpellBar

Canonical instructions for this repository. Workspace rules: `~/Developer/AGENTS.md`. Program rules for the Mac
apps: `~/Developer/Projects/Software/mac-utilities/AGENTS.md`.

## What it is

A menu bar app that gives English typing the Japanese IME's conversion step: type, tap right Shift, pick a
candidate, confirm. It exists because the Touch Bar's typing suggestions have no replacement on current Macs, and
because macOS's own inline prediction only works inside AppKit text views — not in VS Code, Chrome or terminals.

The user types Japanese and English from the Japanese input source's alphanumeric mode (the `¥` key is mapped to
`\`), so **never suggest switching to the ABC input source**, and never ship a fix that only works in some apps.

## Stack

Swift with AppKit, no Xcode project and no dependencies. `build.sh` compiles `Sources/*.swift` with `swiftc` and
assembles `SpellBar.app` by hand. Apple silicon only (arm64), deployment target macOS 13 set with `-target`;
developed and tested on macOS 26 only.

## Architecture

| File | Responsibility |
|---|---|
| `main.swift` | `AppDelegate`: menu bar item, menu, permission prompt, login item, migration from the previous bundle identifier. Also the `--selftest` mode, which is the test suite. |
| `Engine.swift` | The core. A `CGEventTap` sees every key; decides what to pass, swallow or replace. Owns the conversion state machine and `Injector`, which types the replacement. |
| `WordTracker.swift` | Pure state: the word behind the caret, followed from keystrokes alone. `ConversionTarget.choose` decides between it and what the app's text actually says. |
| `TextContext.swift` | Reads the word around the caret through the accessibility API, for reconversion after the caret moves. |
| `CaretLocator.swift` | The caret's screen rectangle, so the window can follow it. |
| `Candidates.swift` | `NSSpellChecker` completions and guesses, the programming-term list, fuzzy rescue. |
| `Learning.swift` | Remembers chosen corrections in `~/.config/spellbar/learned.json`. |
| `Definitions.swift` | macOS dictionary lookups, condensed to one line. |
| `CandidateBar.swift` | The floating panel and its drawing; placement and the all-Spaces registration. |
| `SeedTerms.swift`, `Logging.swift` | Built-in programming words; the log subsystem. |
| `Resources/Localizable.xcstrings` | Every interface text, in English (the source) and Japanese. `build.sh` compiles it into `en.lproj` and `ja.lproj`. |
| `tools/check_localization.py` | Run by `build.sh`: every `String(localized: "…")` in `Sources/` must be in the catalog with both languages. |

## Things that were hard to get right

Do not undo these without reading why.

- **Never block the tap callback.** It runs on the main run loop. Candidate lookups go to `CandidateEngine.queue`,
  accessibility queries to `Engine.axQueue`.
- **Never ask another app anything on the main thread.** `CandidateBar` finds the caret on
  `CaretLocator.queue` and shows the window when the answer arrives. A slow app on the main thread stalls the event
  tap, and with it every key typed anywhere.
- **Believe a caret position only when it is plausible.** `CaretLocator` accepts the caret rectangle if it is about
  one line high and not at the screen's corner, and an input field's frame only if its role is a text input and it
  is not document-sized. A remote desktop window reports its whole frame, which once pinned the window to the top
  left corner. With no believable position the window sits at the bottom.
- **Do not cache the input source.** macOS coalesces distributed notifications for a menu bar app, which is almost
  never active, so a cached "kana mode" went stale and the app fell silent. Reading it per event costs 0.4 µs.
- **Re-register the panel on every Space each time it is shown.** The window server drops that registration across
  sleep and after a login-item launch, which pins the window to one desktop. `ensureOnActiveSpace` also rebuilds
  the panel as a last resort.
- **The app's text wins over the keystroke model, but only when they agree on where the word ends.** macOS rewrites
  text behind the app's back (two spaces become ". ", autocorrect); some apps report their text a moment late, and
  trusting a stale reading deletes the wrong number of characters.
- **The panel must not take focus** (`.nonactivatingPanel`), and its height and left edge must stay steady while a
  word is being typed.
- **Keep quiet** during secure input and kana composition.

## Localization

Interface text is English with a Japanese translation, never a string literal shown to the user. Write
`String(localized: "English text")` with a literal (not a variable), add the same text as a key to
`Resources/Localizable.xcstrings` with `en` and `ja` values, and let `build.sh` check it. Japanese uses full-width `，` and `．`.
`CFBundleLocalizations` in `build.sh` lists the languages; both `.lproj` folders in the bundle are also what makes
macOS offer a per-app language for the app. Dictionary meanings are not localized text: they come from whatever
dictionary the user ranks first, and `Definitions.condense` handles both Japanese and English entries.

To try a language without changing the Mac's setting: `SpellBar --selftest -AppleLanguages "(ja)"`.

## Commands

```sh
./build.sh                                        # compile, assemble and sign
./SpellBar.app/Contents/MacOS/SpellBar --selftest # the tests; no permissions needed
cp -R SpellBar.app ~/Applications/                # install
/usr/bin/log show --last 5m --predicate 'subsystem == "dev.kosuke.SpellBar"'
```

`log` is a zsh builtin, hence the absolute path. Signing, and why permissions survive a rebuild only with the
shared certificate, are in `docs/code-signing.md`.

## Release

Tags are `vX.Y.Z`, annotated, with a message saying what changed. Version numbers live in the Info.plist inside
`build.sh`. Push only `main` and tags.

A release is a `.dmg` holding the signed app and a link to `/Applications`, with its SHA-256 beside it. It is signed
but not notarized, so the first launch needs Open Anyway. Build it from the same bundle the user tested:

```sh
mkdir -p dist/stage && cp -R SpellBar.app dist/stage/ && ln -s /Applications dist/stage/Applications
hdiutil create -volname SpellBar -srcfolder dist/stage -ov -format UDZO dist/SpellBar-X.Y.Z.dmg
(cd dist && shasum -a 256 SpellBar-X.Y.Z.dmg > SpellBar-X.Y.Z.dmg.sha256)   # bare file name, so `shasum -c` works beside it
```

## Still to do

- Candidate quality: the programming-term fuzzy match sometimes answers a plain English misspelling
  (`recie` → `redis`).
