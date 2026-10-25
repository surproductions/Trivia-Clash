#!/usr/bin/env python3
"""Trivia Clash question-bank tool.

  questions.py validate          check every file in questions/ (exit 1 on any error)
  questions.py stats             print counts per category and difficulty
  questions.py build             validate, then write:
                                   ios/TriviaClash/Resources/questions.bin  (AES-GCM encrypted bundle)
                                   database/seed/questions.sql               (upsert for the online backend)
                                   docs/QUESTION_STATS.md
  questions.py check-bundle      verify the committed bundle matches questions/ (used by CI)

Source files use a compact row format:
  [difficulty(e|m|h), prompt, correct, wrong1, wrong2, wrong3, explanation, source]
where source is either a URL or "wp:Article_Title" (an English Wikipedia article).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QDIR = ROOT / "questions"
BUNDLE = ROOT / "ios" / "TriviaClash" / "Resources" / "questions.bin"
SWIFT_KEY = ROOT / "ios" / "TriviaClash" / "Engine" / "BundleKey.swift"
SEED = ROOT / "database" / "seed" / "questions.sql"
STATS = ROOT / "docs" / "QUESTION_STATS.md"
KEY_FILE = QDIR / "bundle_key.hex"

CATEGORIES = {
    "general": "General Knowledge", "science": "Science and Nature", "history": "History",
    "geography": "Geography", "sports": "Sports", "screen": "Movies and Television",
    "music": "Music", "games": "Video Games", "tech": "Technology", "food": "Food and Drink",
    "arts": "Art and Literature", "animals": "Animals", "space": "Space and Astronomy",
    "mythology": "Mythology", "popculture": "Pop Culture", "math": "Mathematics and Logic",
}
DIFFICULTY = {"e": "easy", "m": "medium", "h": "hard"}
VERIFIED_ON = "2026-10-25"
NEAR_DUP_THRESHOLD = 0.8
STOPWORDS = set("a an the of in on is was which what who whom whose to for by with and or as at from that this these those "
                "it its be are were did does do has have had into than then most known name called".split())


def norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9 ]+", " ", text.lower()).strip()


def tokens(text: str) -> set[str]:
    return {t for t in norm(text).split() if t not in STOPWORDS and len(t) > 1}


def source_url(src: str) -> str:
    if src.startswith("wp:"):
        return "https://en.wikipedia.org/wiki/" + src[3:]
    return src


def question_id(category: str, prompt: str) -> str:
    return f"{category}-{hashlib.sha1(norm(prompt).encode()).hexdigest()[:10]}"


def load() -> tuple[list[dict], list[str]]:
    questions: list[dict] = []
    errors: list[str] = []
    files = sorted(QDIR.glob("*.json"))
    if not files:
        errors.append("no question files found")
    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"{path.name}: invalid JSON: {exc}")
            continue
        category = data.get("category")
        if category not in CATEGORIES:
            errors.append(f"{path.name}: unknown category {category!r}")
            continue
        if path.stem != category:
            errors.append(f"{path.name}: file name must match category {category!r}")
        for n, row in enumerate(data.get("questions", []), start=1):
            where = f"{path.name}#{n}"
            if not isinstance(row, list) or len(row) != 8 or not all(isinstance(x, str) for x in row):
                errors.append(f"{where}: row must be 8 strings")
                continue
            diff, prompt, correct, w1, w2, w3, explanation, source = (x.strip() for x in row)
            options = [correct, w1, w2, w3]
            if diff not in DIFFICULTY:
                errors.append(f"{where}: invalid difficulty {diff!r}")
            if not 10 <= len(prompt) <= 300:
                errors.append(f"{where}: prompt length {len(prompt)} outside 10–300")
            if any(not o for o in options):
                errors.append(f"{where}: empty option")
            if any(len(o) > 80 for o in options):
                errors.append(f"{where}: option longer than 80 characters")
            if len({" ".join(o.casefold().split()) for o in options}) != 4:
                errors.append(f"{where}: duplicate answer options {options}")
            if len(explanation) < 10:
                errors.append(f"{where}: missing explanation")
            if not (source.startswith("wp:") and len(source) > 3 and " " not in source) and not source.startswith("https://"):
                errors.append(f"{where}: source must be wp:Title or an https URL")
            questions.append({
                "id": question_id(category, prompt), "category": category, "difficulty": DIFFICULTY.get(diff, diff),
                "prompt": prompt, "correct": correct, "options": options, "explanation": explanation,
                "source": source_url(source), "where": where,
            })
    return questions, errors


def check(questions: list[dict]) -> list[str]:
    errors: list[str] = []
    by_id: dict[str, dict] = {}
    by_text: dict[str, dict] = {}
    for q in questions:
        if q["id"] in by_id:
            errors.append(f"{q['where']}: duplicate id {q['id']} (same prompt as {by_id[q['id']]['where']})")
        by_id[q["id"]] = q
        key = norm(q["prompt"])
        if key in by_text:
            errors.append(f"{q['where']}: duplicate prompt text (also {by_text[key]['where']})")
        by_text[key] = q
    # Near-duplicates: very similar wording with the same correct answer.
    by_answer: dict[str, list[dict]] = defaultdict(list)
    for q in questions:
        by_answer[norm(q["correct"])].append(q)
    for group in by_answer.values():
        for i, a in enumerate(group):
            ta = tokens(a["prompt"])
            for b in group[i + 1:]:
                tb = tokens(b["prompt"])
                if ta and tb and len(ta & tb) / len(ta | tb) >= NEAR_DUP_THRESHOLD:
                    errors.append(f"{b['where']}: near-duplicate of {a['where']} ({a['prompt']!r})")
    return errors


def shuffled(q: dict) -> tuple[list[str], int]:
    """Deterministic per-question option order so the bundle never stores the answer first."""
    order = sorted(range(4), key=lambda i: hashlib.sha256(f"{q['id']}:{i}".encode()).digest())
    return [q["options"][i] for i in order], order.index(0)


def bundle_payload(questions: list[dict]) -> bytes:
    items = []
    for q in sorted(questions, key=lambda x: x["id"]):
        options, answer = shuffled(q)
        items.append({"id": q["id"], "c": q["category"], "d": q["difficulty"], "p": q["prompt"],
                      "o": options, "a": answer, "e": q["explanation"], "s": q["source"]})
    return json.dumps({"v": 1, "verified_on": VERIFIED_ON, "q": items}, ensure_ascii=False,
                      separators=(",", ":")).encode()


def key() -> bytes:
    if not KEY_FILE.exists():
        KEY_FILE.write_text(os.urandom(32).hex() + "\n")
    return bytes.fromhex(KEY_FILE.read_text().strip())


def encrypt(payload: bytes, nonce: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    return nonce + AESGCM(key()).encrypt(nonce, payload, b"trivia-clash-bundle-v1")


def decrypt(blob: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    return AESGCM(key()).decrypt(blob[:12], blob[12:], b"trivia-clash-bundle-v1")


def swift_key_source() -> str:
    """Key bytes split into two XOR shares so the raw key never appears as one literal."""
    k = key()
    mask = hashlib.sha256(b"tc-mask" + k).digest()
    a = ", ".join(f"0x{b ^ m:02x}" for b, m in zip(k, mask))
    b = ", ".join(f"0x{m:02x}" for m in mask)
    return ("// Generated by scripts/questions.py build. Do not edit by hand.\n"
            "// Obfuscation only: it keeps answers out of plain sight in the app bundle, it is not DRM.\n"
            "enum BundleKey {\n"
            f"    private static let shareA: [UInt8] = [{a}]\n"
            f"    private static let shareB: [UInt8] = [{b}]\n"
            "    static var bytes: [UInt8] { zip(shareA, shareB).map { $0 ^ $1 } }\n"
            "    static let associatedData = Array(\"trivia-clash-bundle-v1\".utf8)\n"
            "}\n")


def sql_literal(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def seed_sql(questions: list[dict]) -> str:
    lines = ["-- Generated by scripts/questions.py build. Do not edit by hand.",
             "insert into tc_private.questions (id, category, difficulty, prompt, options, correct_index, explanation, source, verified_on, review_status) values"]
    rows = []
    for q in sorted(questions, key=lambda x: x["id"]):
        options, answer = shuffled(q)
        opts = "array[" + ", ".join(sql_literal(o) for o in options) + "]"
        rows.append(f"({sql_literal(q['id'])}, {sql_literal(q['category'])}, {sql_literal(q['difficulty'])}, "
                    f"{sql_literal(q['prompt'])}, {opts}, {answer}, {sql_literal(q['explanation'])}, "
                    f"{sql_literal(q['source'])}, date '{VERIFIED_ON}', 'approved')")
    lines.append(",\n".join(rows))
    lines.append("on conflict (id) do update set category = excluded.category, difficulty = excluded.difficulty, "
                 "prompt = excluded.prompt, options = excluded.options, correct_index = excluded.correct_index, "
                 "explanation = excluded.explanation, source = excluded.source, verified_on = excluded.verified_on, "
                 "review_status = excluded.review_status, updated_at = now();")
    return "\n".join(lines) + "\n"


def stats_md(questions: list[dict]) -> str:
    per = defaultdict(Counter)
    for q in questions:
        per[q["category"]][q["difficulty"]] += 1
    out = ["# Question bank statistics", "", f"Generated by `scripts/questions.py build`. Total: **{len(questions)}** questions.", "",
           "| Category | Easy | Medium | Hard | Total |", "|---|---:|---:|---:|---:|"]
    for cat, label in CATEGORIES.items():
        c = per[cat]
        out.append(f"| {label} | {c['easy']} | {c['medium']} | {c['hard']} | {sum(c.values())} |")
    t = Counter(q["difficulty"] for q in questions)
    out.append(f"| **All** | {t['easy']} | {t['medium']} | {t['hard']} | {len(questions)} |")
    return "\n".join(out) + "\n"


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "validate"
    questions, errors = load()
    errors += check(questions)
    if errors:
        print(f"{len(errors)} problem(s):")
        for e in errors:
            print("  -", e)
        return 1
    if cmd == "validate":
        print(f"OK: {len(questions)} questions in {len({q['category'] for q in questions})} categories")
    elif cmd == "stats":
        print(stats_md(questions))
    elif cmd == "build":
        payload = bundle_payload(questions)
        nonce = hashlib.sha256(payload).digest()[:12]  # deterministic → reproducible bundle
        BUNDLE.parent.mkdir(parents=True, exist_ok=True)
        BUNDLE.write_bytes(encrypt(payload, nonce))
        SWIFT_KEY.parent.mkdir(parents=True, exist_ok=True)
        SWIFT_KEY.write_text(swift_key_source(), encoding="utf-8")
        SEED.parent.mkdir(parents=True, exist_ok=True)
        SEED.write_text(seed_sql(questions), encoding="utf-8")
        STATS.write_text(stats_md(questions), encoding="utf-8")
        print(f"Built {BUNDLE.relative_to(ROOT)} ({BUNDLE.stat().st_size} bytes), "
              f"{SEED.relative_to(ROOT)}, {STATS.relative_to(ROOT)} from {len(questions)} questions")
    elif cmd == "check-bundle":
        if not BUNDLE.exists():
            print("bundle missing; run scripts/questions.py build")
            return 1
        if decrypt(BUNDLE.read_bytes()) != bundle_payload(questions):
            print("bundle is out of date; run scripts/questions.py build and commit the result")
            return 1
        print("bundle up to date")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
