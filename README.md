# SpellBar

A small menu bar app that brings the Japanese IME's *conversion* to English typing on macOS.

Type a word, tap **right Shift**, and a candidate window appears; tap again to walk through the candidates, press
Return to confirm. The candidates come from `NSSpellChecker` — the same engine that fed the Touch Bar's typing
suggestions — so they are the ones macOS already knows, shown on a Mac that has no Touch Bar.

Because SpellBar reads the keyboard through an event tap, it works in apps that do not use AppKit's text views, where
the system's own inline prediction and autocorrect never appear: VS Code, Chrome, Electron apps, terminals.

## What it does

- **Conversion on a key.** Right Shift converts the word behind the caret. Nothing is replaced until you confirm.
- **Candidates while you type**, from the first letters, if you prefer them always visible (on by default).
- **Reconversion.** The word stays reachable after a space, after Backspace, and after you move the caret back to it
  — by clicking into it, selecting it, or landing in the middle of it.
- **It learns.** The correction you pick for a misspelling is offered first the next time you make it. No list to
  maintain by hand.
- **Meanings.** The selected candidate's dictionary definition appears under the candidates, so you can tell
  `affect` from `effect`. `⌘D` opens the full entry in Dictionary.app. The text comes from the dictionaries you
  have enabled in Dictionary.app, in the order you set there: an English–Japanese dictionary on top gives Japanese
  glosses, an English dictionary on top gives English definitions.
- **Programming words.** `async`, `kwargs`, `kubernetes` and friends are known, alongside the English dictionary.
- **It stays out of the way.** The window follows the caret like an IME's, keeps its height and left edge steady, and
  disappears while the Japanese input method is composing kana or while macOS reports secure input.

## Keys

| Key | Action |
|---|---|
| **Right Shift** (tapped alone) | Convert the word behind the caret, or move to the next candidate |
| `return` | Confirm |
| `space` | Confirm and type a space |
| `esc` | Put the original spelling back |
| `↓` / `tab`, `↑` | Next, previous candidate |
| `⌘1`–`⌘5` | Confirm that candidate directly |
| `⌘D` | Open the word in Dictionary.app |

Right Shift counts as the conversion key only when it is pressed and released with no other key in between, so
`Shift`+letter is unaffected and the key still reaches the app.

## Requirements

macOS 13 or later, Apple silicon or Intel. Developed and used on macOS 26.

## Languages

The menu and alerts are in **English and Japanese**. SpellBar follows your Mac's language order; to use the other
one for this app alone, open **System Settings → General → Language & Region → Applications**, add SpellBar, and
pick a language. Restart SpellBar afterwards.

## Install

Download `SpellBar-1.2.0.dmg` from [Releases](../../releases), open it, and drag **SpellBar** onto the
**Applications** folder in the same window.

If you want to check the download first, compare it with the `.sha256` file published beside it:

```sh
shasum -a 256 ~/Downloads/SpellBar-1.2.0.dmg
```

The app is signed but **not notarized**, so the first launch is blocked. Open it once, then go to **System Settings →
Privacy & Security**, find the message about SpellBar near the bottom, and choose **Open Anyway**.

Then grant two permissions in **System Settings → Privacy & Security** and restart the app:

- **Accessibility**
- **Input Monitoring**

Both are explained in [PRIVACY.md](PRIVACY.md). If SpellBar's icon shows a warning triangle, one of them is missing.

### Upgrading from a build older than 1.1.0

The bundle identifier changed in 1.1.0, so macOS treats the app as new: grant the two permissions again, and remove
the old `SpellBar` entries in Accessibility and Input Monitoring with the `−` button. Your settings and learned words
are carried over automatically. If an old SpellBar login item lingers in **System Settings → General → Login Items**,
remove it there.

## When it does nothing

Open the SpellBar menu: its **first line says why it is not reacting right now** — turned off, missing a permission,
the Japanese input is typing kana, or macOS has secure input on (and which app switched it on).

Secure input deserves a word. While any app has it on, macOS hides every keystroke from every other app, SpellBar
included. Password fields switch it on; some apps forget to switch it off again. Nothing SpellBar can do gets
around it, but the menu names the app, and quitting that app or leaving its password field clears it.

## Known limits

SpellBar sees every key you type, but it can only place its window and read the text around the caret where an app
answers accessibility questions.

- **Remote desktop, virtual machines and editors that draw their own text** report no caret position. The window
  stays at the bottom of the screen (or the top, if you chose that) instead of following the caret, and reconverting
  a word after moving the caret does not work.
- **Web pages.** Chromium-based browsers and Electron apps may not expose a page's text fields to accessibility
  unless they are told an assistive tool is running; where they do not, the window stays at the bottom. Editors that
  draw their own text, Google Docs among them, may also not accept the keys SpellBar types to replace a word. That
  has not been verified.
- **Secure input**, as above.

## Settings

Everything is in the menu bar item: enable or disable, always-on candidates, start at login, and where the candidate
window goes (follow the caret, always at the bottom, always at the top). The position submenu also has a debug
readout that shows how the caret position was obtained, for apps where following it fails.

Add your own words — project names, APIs, anything the dictionary lacks — one per line:

```sh
mkdir -p ~/.config/spellbar
echo "kubectl" >> ~/.config/spellbar/terms.txt
```

What SpellBar has learned lives in `~/.config/spellbar/learned.json`. Delete the file to forget it.

## Build

No Xcode project and no dependencies: one script compiles the sources with `swiftc` and assembles the bundle.
Xcode has to be installed, because its `xcstringstool` compiles the String Catalog of the interface texts.

```sh
./build.sh
```

The self-test runs the candidate engine, the word tracking and the reconversion rules without needing any permission:

```sh
./SpellBar.app/Contents/MacOS/SpellBar --selftest
```

`build.sh` signs with a self-signed certificate when it is in the keychain and falls back to ad-hoc signing with a
warning. [docs/code-signing.md](docs/code-signing.md) explains why that matters: with ad-hoc signing macOS forgets
the two permissions on every rebuild.

## Privacy

SpellBar has no network code at all, and nothing you type is sent anywhere. It reads the keyboard, which is a serious
permission to hand out — which is why the source is here to read. See [PRIVACY.md](PRIVACY.md).

## Licence

MIT, Copyright (c) 2026 Kosuke Satake. See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md); SpellBar bundles
no third-party code.

Issues are welcome. Code contributions are not accepted at the moment, to keep the copyright with one holder.

This app was built with the help of Claude (Anthropic) through Claude Code; design, review and testing are by Kosuke
Satake. Anthropic does not endorse this app.
