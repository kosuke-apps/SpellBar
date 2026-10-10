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
assembles `SpellBar.app` by hand. Deployment target macOS 13; developed on macOS 26.

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

## Things that were hard to get right

Do not undo these without reading why.

- **Never block the tap callback.** It runs on the main run loop. Candidate lookups go to `CandidateEngine.queue`,
  accessibility queries to `Engine.axQueue`.
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
`build.sh`. Releases are zips made with `ditto -c -k --keepParent SpellBar.app SpellBar-X.Y.Z.zip`, signed but not
notarized. Push only `main` and tags.

## Still to do

- The menu and the alerts are hard-coded Japanese. The program rules want English as the base language with a
  Japanese localization through a String Catalog. Comments in the older files are Japanese too.
- Candidate quality: the programming-term fuzzy match sometimes answers a plain English misspelling
  (`recie` → `redis`).
