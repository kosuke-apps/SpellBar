#!/usr/bin/env python3
"""Checks that the String Catalog and the sources agree.

Every `String(localized: "...")` in Sources/ must be a key of Resources/Localizable.xcstrings, and every key must
have a translation in each language. Exits non-zero on a missing string, so a build never ships one that falls
back to the key in the wrong language.
"""
import glob
import json
import re
import sys

LANGUAGES = ("en", "ja")

catalog = json.load(open("Resources/Localizable.xcstrings", encoding="utf-8"))
keys = catalog["strings"]

used = set()
for path in sorted(glob.glob("Sources/*.swift")):
    for match in re.finditer(r'String\(localized: "((?:[^"\\]|\\.)*)"\)', open(path, encoding="utf-8").read()):
        used.add(match.group(1).replace('\\"', '"').replace("\\n", "\n"))

errors = []
for key in sorted(used - set(keys)):
    errors.append(f"missing from the catalog: {key!r}")
for key, entry in keys.items():
    for lang in LANGUAGES:
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if not unit.get("value"):
            errors.append(f"no {lang} translation: {key!r}")
unused = sorted(set(keys) - used)

for line in errors:
    print("error:", line, file=sys.stderr)
for key in unused:
    print("warning: unused string:", repr(key), file=sys.stderr)
if errors:
    sys.exit(1)
print(f"localization ok: {len(used)} strings in {', '.join(LANGUAGES)}")
