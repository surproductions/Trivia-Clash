# Question bank

- **4,908 original questions** across 16 categories (at least 300 per category: about 140 easy, 100 medium and 60 hard). Counts by category and difficulty are in [QUESTION_STATS.md](QUESTION_STATS.md).
- Written for Trivia Clasher. Nothing is copied from commercial trivia sets.
- Focused on timeless facts. Anything that changes over time (sports records, office holders, box-office rankings) is avoided or phrased as a fixed historical fact.

## Format

One file per category, `questions/<category>.json`:

```json
{
  "category": "science",
  "format": "[difficulty, prompt, correct, wrong1, wrong2, wrong3, explanation, source]",
  "questions": [
    ["m", "What is the SI unit of force?", "Newton", "Joule", "Pascal", "Watt",
     "Force is measured in newtons; one newton accelerates 1 kg at 1 m/s².", "wp:Newton_(unit)"]
  ]
}
```

- `difficulty`: `e` (easy), `m` (medium) or `h` (hard).
- The correct answer is always written first in the source file. The build step shuffles option order deterministically per question, and the app shuffles again per player and round.
- `source`: `wp:Article_Title` for English Wikipedia, or a full `https://` URL.
- Category keys: `general, science, history, geography, sports, screen, music, games, tech, food, arts, animals, space, mythology, popculture, math`.

## Workflow

```bash
pip install cryptography
python3 scripts/questions.py validate   # checks only
python3 scripts/questions.py build      # checks, then regenerates:
                                        #   ios/TriviaClash/Resources/questions.bin (encrypted app bundle)
                                        #   ios/TriviaClash/Engine/BundleKey.swift
                                        #   database/seed/questions.sql (online backend upsert)
                                        #   docs/QUESTION_STATS.md
python3 scripts/check_sources.py        # every wp: reference resolves to a real article (needs network)
```

Commit the regenerated files. CI (`.github/workflows/questions.yml`) fails if the committed bundle doesn't match the JSON.

## What the validator enforces

- Exactly 8 fields per row. The category must be known and match the file name.
- Difficulty must be `e`, `m` or `h`. Prompts must be 10–300 characters, options at most 80.
- Four non-empty options, with no duplicates (case- and whitespace-insensitive).
- A non-empty explanation, and a source that is `wp:` or `https://`.
- No duplicate IDs or prompts, and no near-duplicates (same correct answer with ≥ 80% word overlap).
- IDs are stable: `<category>-<sha1(normalised prompt)[:10]>`. Rewording a prompt creates a new ID, which is intended, because a changed question should be treated as new.

## Review status (honest note)

Every question was written and reviewed for accuracy, ambiguity and difficulty by the AI assistant that built this project, and checked by the automated validator. The CI source check confirms that each referenced Wikipedia article exists. That does **not** prove the article supports the fact. The questions have **not yet been reviewed by a human fact-checker**. Before a public launch, sample-review each category and record the reviewer and date.

## Adding categories or packs

1. Add the key to `CATEGORIES` in `scripts/questions.py`.
2. Add a case to `TriviaCategory` in `ios/TriviaClash/Engine/Models.swift` (title and SF Symbol).
3. Add the key to the `category` check in `database/migrations/0001_schema.sql`.
4. Create the JSON file and run `build`.

The engine, selection and UI need no other changes.
