# Scoring

All points are calculated by the match authority: the player's own phone in solo, the host's phone in nearby play, and the database in the future online mode. Clients never send scores or correctness. Nearby guests do send their own reaction time, but the host accepts it only within the network delay it measured itself (see the speed bonus below).

| Component | Rule |
|---|---|
| Correct answer | **1,000** |
| Speed bonus | `floor(250 × remainingMs / 10,000)`, where `remainingMs = 10,000 − reaction time` and reaction time is measured from the synchronised reveal. In nearby play the guest's network delay is credited back within the round-trip time the host measured (max 400 ms), so host and guests are scored alike |
| Streak bonus | `50 × min(previous consecutive correct answers, 4)`, so +50, +100, +150, then a cap of +200 |
| Final question (optional) | ×2 on the whole question score when the host enables "Double-points finale" |
| Wrong answer | 0, streak resets |
| No answer before the deadline | 0, streak resets |

Examples:

- Correct with 7.3 s left, first in a streak: 1,000 + 182 + 0 = **1,182**.
- Third correct in a row with 2 s left: 1,000 + 50 + 100 = **1,150**.
- Final double, correct instantly, fifth in a row: (1,000 + 250 + 200) × 2 = **2,900**.

A perfect 10-question game without the finale tops out around 14,000 points. Speed and streaks can add at most 45% over base, so consistent knowledge beats lucky guessing.

## Integrity rules

- **One answer per player per round.** The first accepted answer is final. Retries return `already_answered` with the stored choice and score nothing.
- **Strict deadline.** An answer whose reaction time is 10 s or more is rejected (`too_late`). For remote players the host accepts arrivals up to 400 ms past the nominal deadline, so taps made in time still count.
- **Scores are hidden until the round closes.** Per-answer points are stored privately and applied at close, so scoreboards can't leak correctness mid-round.
- **Scores can't go negative.** The database enforces `check (score >= 0)`.

## Standings and tie-breakers

Players are ordered by:

1. Total score (higher first)
2. Correct answers (more first)
3. Total time spent on correct answers (less first)
4. Join order (display order only)

Players equal on 1–3 **share a rank**, and the results screen announces a shared victory.

## Teams

Team score is the **average** of its members' scores, rounded. This keeps uneven teams (for example 3 vs 2) fair. The results screen also shows the team total and each player's share of it. Teams are ordered by average score, then total correct answers. Teams equal on both share a rank.

The unit tests in `ios/TriviaClashTests/EngineTests.swift` (`ScoringTests`, `MatchEngineTests`, `TeamTests`) cover every rule above. The online backend mirrors them in `tc_private.score`.
