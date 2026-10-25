#!/usr/bin/env python3
"""Unit tests for the question-bank validator (python3 -m unittest scripts/test_questions.py)."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("questions", Path(__file__).with_name("questions.py"))
Q = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(Q)

GOOD = ["e", "What is the capital of France?", "Paris", "Lyon", "Nice", "Lille", "Paris is the capital.", "wp:Paris"]


class ValidatorTests(unittest.TestCase):
    def run_rows(self, rows, category="general", filename=None):
        with tempfile.TemporaryDirectory() as tmp:
            qdir = Path(tmp)
            (qdir / f"{filename or category}.json").write_text(json.dumps({"category": category, "questions": rows}))
            old = Q.QDIR
            Q.QDIR = qdir
            try:
                questions, errors = Q.load()
                return questions, errors + Q.check(questions)
            finally:
                Q.QDIR = old

    def test_valid_row_passes(self):
        questions, errors = self.run_rows([GOOD])
        self.assertEqual(errors, [])
        self.assertEqual(questions[0]["id"], Q.question_id("general", GOOD[1]))
        self.assertEqual(questions[0]["source"], "https://en.wikipedia.org/wiki/Paris")

    def test_duplicate_prompt_is_rejected(self):
        _, errors = self.run_rows([GOOD, list(GOOD)])
        self.assertTrue(any("duplicate" in e for e in errors))

    def test_near_duplicate_is_rejected(self):
        near = list(GOOD)
        near[1] = "What's the capital of France?"
        _, errors = self.run_rows([GOOD, near])
        self.assertTrue(any("near-duplicate" in e for e in errors), errors)

    def test_duplicate_options_rejected(self):
        bad = list(GOOD)
        bad[3] = "paris"
        _, errors = self.run_rows([bad])
        self.assertTrue(any("duplicate answer options" in e for e in errors))

    def test_wrong_field_count_rejected(self):
        _, errors = self.run_rows([GOOD[:7]])
        self.assertTrue(any("8 strings" in e for e in errors))

    def test_invalid_difficulty_and_source_rejected(self):
        bad = list(GOOD)
        bad[0] = "x"
        bad[7] = "my memory"
        _, errors = self.run_rows([bad])
        self.assertTrue(any("difficulty" in e for e in errors))
        self.assertTrue(any("source" in e for e in errors))

    def test_missing_explanation_rejected(self):
        bad = list(GOOD)
        bad[6] = ""
        _, errors = self.run_rows([bad])
        self.assertTrue(any("explanation" in e for e in errors))

    def test_unknown_category_rejected(self):
        _, errors = self.run_rows([GOOD], category="cooking")
        self.assertTrue(any("unknown category" in e for e in errors))

    def test_shuffle_keeps_answer_mapping(self):
        questions, _ = self.run_rows([GOOD])
        options, answer = Q.shuffled(questions[0])
        self.assertEqual(options[answer], "Paris")
        self.assertEqual(sorted(options), sorted(GOOD[2:6]))

    def test_real_bank_is_valid(self):
        questions, errors = Q.load()
        errors += Q.check(questions)
        self.assertEqual(errors, [])
        self.assertGreaterEqual(len(questions), 1000)

    def test_bundle_round_trips(self):
        questions, _ = Q.load()
        payload = Q.bundle_payload(questions)
        blob = Q.encrypt(payload, b"\x00" * 12)
        self.assertEqual(Q.decrypt(blob), payload)
        self.assertNotIn(b"Paris", blob)


if __name__ == "__main__":
    unittest.main()
