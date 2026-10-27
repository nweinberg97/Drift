#!/usr/bin/env python3
"""Renames the app everywhere a person can see the name.

    python3 scripts/rename.py "New Name"
    python3 scripts/gen-xcodeproj.py

Changes:
  - the app's display name (menus, windows, notifications read it at runtime)
  - the product name in the Xcode project, so the installed app is "New Name.app"
  - the website (docs/*.html) and the store copy (appstore/*.md), README

Leaves alone: the bundle ID (never shown), code identifiers, the drift://
URL scheme, file paths and GitHub URLs. Run with --dry-run to preview.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 1 or not args[0].strip():
        sys.exit(__doc__)
    new = args[0].strip()
    old = current_name()
    if new == old:
        sys.exit(f"Already called {old}.")

    changes = []

    def edit(rel, fn):
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            return
        with open(path, encoding="utf-8") as f:
            before = f.read()
        after = fn(before)
        if after != before:
            changes.append(rel)
            if not dry:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(after)

    plist_name = lambda s: re.sub(
        r"(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{new}\g<2>", s)
    edit("packaging/Info.plist", lambda s: re.sub(
        r"(<key>CFBundleName</key>\s*<string>)[^<$]*(</string>)", rf"\g<1>{new}\g<2>", plist_name(s)))
    edit("packaging/AppStore/Config/Info.plist", plist_name)
    edit("scripts/gen-xcodeproj.py", lambda s: re.sub(
        r'("name": ")[^"]*(",)', rf"\g<1>{new}\g<2>", s, count=1))
    edit("Sources/Drift/App/AppInfo.swift", lambda s: s.replace(f'return "{old}"', f'return "{new}"'))

    # Visible text only: not URLs, paths, file names, code, or the URL scheme.
    word = re.compile(rf"(?<![/\w.@-])(?<!cd ){re.escape(old)}(?![\w/.-]|\.app|://)")
    for d in ("docs", "appstore"):
        for name in sorted(os.listdir(os.path.join(ROOT, d))):
            if name.endswith((".html", ".md")):
                edit(f"{d}/{name}", lambda s: word.sub(new, s))
    edit("README.md", lambda s: word.sub(new, s))

    verb = "Would change" if dry else "Changed"
    print(f"{verb} {old} → {new} in:")
    for c in changes:
        print("  " + c)
    if not dry:
        print("\nNow run: python3 scripts/gen-xcodeproj.py")


def current_name() -> str:
    with open(os.path.join(ROOT, "packaging/AppStore/Config/Info.plist"), encoding="utf-8") as f:
        m = re.search(r"<key>CFBundleDisplayName</key>\s*<string>([^<]*)</string>", f.read())
    return m.group(1) if m else "Drift"


if __name__ == "__main__":
    main()
