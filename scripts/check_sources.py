#!/usr/bin/env python3
"""Checks that every Wikipedia reference in the question bank points to an
existing article (following redirects). Network access required; run in CI.

  python3 scripts/check_sources.py
"""
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://en.wikipedia.org/w/api.php"
HEADERS = {"User-Agent": "TriviaClashSourceCheck/1.0 (https://github.com/surproductions/Trivia-Clash)"}


def titles() -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for path in sorted((ROOT / "questions").glob("*.json")):
        for n, row in enumerate(json.loads(path.read_text())["questions"], start=1):
            src = row[7]
            if src.startswith("wp:"):
                found.setdefault(src[3:].replace("_", " "), []).append(f"{path.name}#{n}")
    return found


def missing(batch: list[str]) -> set[str]:
    params = {"action": "query", "format": "json", "redirects": 1, "titles": "|".join(batch)}
    req = urllib.request.Request(f"{API}?{urllib.parse.urlencode(params)}", headers=HEADERS)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.load(resp)
            break
        except Exception:
            time.sleep(2 ** attempt)
    else:
        raise SystemExit("Wikipedia API unreachable")
    query = data.get("query", {})
    normalized = {n["from"]: n["to"] for n in query.get("normalized", [])}
    absent = {p["title"] for p in query.get("pages", {}).values() if "missing" in p or "invalid" in p}
    return {t for t in batch if normalized.get(t, t) in absent}


def main() -> int:
    refs = titles()
    names = sorted(refs)
    bad: set[str] = set()
    for i in range(0, len(names), 50):
        bad |= missing(names[i:i + 50])
    print(f"Checked {len(names)} distinct Wikipedia articles referenced by the question bank.")
    if bad:
        print(f"{len(bad)} missing article(s):")
        for t in sorted(bad):
            print(f"  - {t}  ({', '.join(refs[t])})")
        return 1
    print("All referenced articles exist.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
