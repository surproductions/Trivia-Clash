#!/usr/bin/env python3
"""Lists question pairs that probably ask the same thing in different words:
same correct answer and overlapping key words. For human review, not a hard error.

  python3 scripts/review_similar.py [category]
"""
import importlib.util
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("q", ROOT / "scripts" / "questions.py")
Q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(Q)

GENERIC = set("how many much does have has number type kind part called name world one two three four five "
              "six seven eight nine ten usually commonly traditionally standard main famous".split())
only = sys.argv[1] if len(sys.argv) > 1 else None
questions, _ = Q.load()
groups = defaultdict(list)
for q in questions:
    groups[Q.norm(q["correct"])].append(q)
for answer, qs in groups.items():
    for i, a in enumerate(qs):
        for b in qs[i + 1:]:
            if only and only not in (a["category"], b["category"]):
                continue
            ta, tb = Q.tokens(a["prompt"]) - GENERIC, Q.tokens(b["prompt"]) - GENERIC
            shared = ta & tb
            if len(shared) >= 2 and len(shared) / min(len(ta), len(tb)) >= 0.4:
                print(f"[{answer}] {a['where']}: {a['prompt']}\n{'':>{len(answer)+3}}{b['where']}: {b['prompt']}\n")
