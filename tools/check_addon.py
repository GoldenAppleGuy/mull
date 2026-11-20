#!/usr/bin/env python3
"""Checks that the RemoteCompanion add-on (layout/Library/RemoteCompanion/AddOns/mull.json) offers the same
settings as the settings page (prefs/Resources/Root.plist): the same number ranges and the same colors.
Run by make before packaging; exits 1 and says what differs."""
import json
import plistlib
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
page = plistlib.loads((root / "prefs/Resources/Root.plist").read_bytes())["items"]
addon = json.loads((root / "layout/Library/RemoteCompanion/AddOns/mull.json").read_text())

page_items = {item["key"]: item for item in page if "key" in item}
problems = []
for setting in addon.get("settings", []):
    key = setting["key"]
    item = page_items.get(key)
    if item is None:
        problems.append(f"{setting['id']}: the settings page has no {key}")
        continue
    if setting["type"] == "number":
        for limit in ("min", "max"):
            if setting.get(limit) != item.get(limit):
                problems.append(f"{setting['id']}: {limit} {setting.get(limit)}, the settings page has {item.get(limit)}")
    if setting["type"] == "choice":
        values = [choice["value"] for choice in setting["choices"]]
        if values != item.get("validValues"):
            problems.append(f"{setting['id']}: choices {values}, the settings page has {item.get('validValues')}")
    if "default" in setting and setting["default"] != item.get("default"):
        problems.append(f"{setting['id']}: default {setting['default']}, the settings page has {item.get('default')}")

for problem in problems:
    print(f"mull.json: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
