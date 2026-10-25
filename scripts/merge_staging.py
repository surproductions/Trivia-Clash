#!/usr/bin/env python3
"""Merges staged question batches into the bank.

  python3 scripts/merge_staging.py questions/_staging/science-1.json [...]

A staging file is {"category": "...", "questions": [rows]} using the same row
format as the bank. Rows that are malformed or duplicate/near-duplicate anything
already in the bank (or earlier in the batch) are rejected and listed, never
merged. Accepted rows are appended to questions/<category>.json and the staging
file is deleted.
"""
import importlib.util
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("q", ROOT / "scripts" / "questions.py")
Q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(Q)
TARGET = {"e": 140, "m": 100, "h": 60}


def write_bank(path: Path, data: dict) -> None:
    with path.open("w", encoding="utf-8") as fh:
        fh.write('{\n  "category": "%s",\n  "format": "%s",\n  "questions": [\n' % (data["category"], data["format"]))
        fh.write(",\n".join("    " + json.dumps(q, ensure_ascii=False) for q in data["questions"]))
        fh.write("\n  ]\n}\n")


def main() -> int:
    for staged in map(Path, sys.argv[1:]):
        batch = json.loads(staged.read_text(encoding="utf-8"))
        cat = batch["category"]
        bank_path = ROOT / "questions" / f"{cat}.json"
        bank = json.loads(bank_path.read_text(encoding="utf-8"))
        accepted, rejected = [], []
        for row in batch["questions"]:
            trial = dict(bank, questions=bank["questions"] + accepted + [row])
            tmp = ROOT / "questions" / f"{cat}.json"
            original = bank_path.read_text(encoding="utf-8")
            write_bank(tmp, trial)
            questions, errors = Q.load()
            errors += Q.check(questions)
            bank_path.write_text(original, encoding="utf-8")
            if errors:
                rejected.append((row[1], errors[0]))
            else:
                accepted.append(row)
        bank["questions"] += accepted
        write_bank(bank_path, bank)
        staged.unlink()
        c = Counter(r[0] for r in bank["questions"])
        print(f"{cat}: +{len(accepted)} accepted, {len(rejected)} rejected → "
              f"easy {c['e']}/{TARGET['e']}, medium {c['m']}/{TARGET['m']}, hard {c['h']}/{TARGET['h']}")
        for prompt, err in rejected:
            print(f"   ✗ {prompt[:70]}  ({err.split(': ', 1)[-1][:90]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
