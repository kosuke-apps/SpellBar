# Privacy

SpellBar works entirely on your Mac. It has no network code of any kind: there is no server, no analytics, no crash
reporting and no update check. Nothing you type is sent anywhere.

## Permissions

| Permission | Why it is needed |
|---|---|
| Input Monitoring | To see the letters you type, so it can follow the word you are writing and offer candidates. This is the same class of permission a keylogger needs, which is why the source is public. |
| Accessibility | To replace a word with the candidate you choose (by sending backspaces and the new text), and to ask the app you are typing in where the caret is and what word is behind it, so the candidate window can follow the caret. |

SpellBar stops watching the keyboard completely while macOS reports secure input — in password fields, for example —
and while the Japanese input method is composing kana.

## What is stored

| What | Where | Why |
|---|---|---|
| Words you picked for a misspelling, with a count | `~/.config/spellbar/learned.json` | So the same correction is offered first next time. Delete the file to forget everything. |
| Whether the login item was set up, the menu bar icon position | the app's preferences | Settings. No text. |

Both stay on your Mac. Nothing else about your typing is written down: candidates and the text read around the caret
are held in memory only for as long as the word is on screen.

The app writes a few lines to the system log — the permission state at launch, and rare repairs such as the candidate
window having to be re-registered. These lines never contain anything you typed. Read them with:

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "dev.kosuke.SpellBar"'
```

## What leaves the app

Pressing `⌘D` opens the word in Dictionary.app. That is the only time SpellBar hands a word to another program, and
Dictionary.app is part of macOS. Candidates, corrections and meanings are produced by macOS itself, on the machine.
