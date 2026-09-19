# Code signing

SpellBar is signed with the certificate shared by every Mac Utilities app, **Mac Utilities Code Signing**. The rule
lives in `mac-utilities/AGENTS.md` under "Code signing"; this page is how to set it up and how to check it.

## Why

macOS remembers privacy permissions (Accessibility, Input Monitoring) by the app's *designated requirement*, the
rule that says which code counts as "this app".

| Signed with | Designated requirement | After a rebuild |
|---|---|---|
| ad-hoc (`codesign -s -`) | `cdhash H"…"`, the hash of this exact binary | permissions are gone |
| the shared certificate | `identifier "local.spellbar" and certificate …` | permissions stay |

The requirement is never reduced to the bundle identifier alone: any binary claiming `local.spellbar` would then
inherit Input Monitoring silently.

## Creating the certificate (once, for all apps)

1. Open Keychain Access: `open -a "Keychain Access"`.
2. Keychain Access → Certificate Assistant → Create a Certificate…
3. Name `Mac Utilities Code Signing`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing*, and tick
   *Let me override defaults*.
4. Validity Period: `3650` days. Leave the other pages at their defaults (RSA 2048, Key Usage *Signature*, Extended
   Key Usage *Code Signing*), and store it in the *login* keychain.

Do not mark the certificate as trusted. Neither `codesign` nor the permission database needs it.

## Backing up the private key

Losing the private key means every user re-grants the permissions after the next update. Back it up outside Git:

1. Keychain Access → login → My Certificates → select *Mac Utilities Code Signing*.
2. File → Export Items… → format *Personal Information Exchange (.p12)*, with a strong password.
3. Keep the `.p12` outside `~/Developer` and the password in a password manager. Delete any other copy.

To restore on another Mac, open the `.p12` and import it into the login keychain.

## How the build uses it

`build.sh` signs with the certificate when exactly one identity of that name is in the keychain. With none it signs
ad-hoc and warns; with several it stops. The first signing asks for keychain access: choose *Always Allow*.

## Checking

```sh
security find-identity -p codesigning          # the certificate is listed
codesign -d -r- SpellBar.app                   # designated => identifier "local.spellbar" and certificate …
/usr/bin/log show --last 5m --predicate 'subsystem == "local.spellbar"'   # accessibility=true inputMonitoring=true after launch
```
