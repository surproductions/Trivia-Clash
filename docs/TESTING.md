# Testing

## Automated: what ran and the results

The latest verified run is [CI run 40202674366](https://github.com/surproductions/Trivia-Clash/actions/runs/40202674366) on commit `3a8c31d`, on 2026-10-25, using Xcode 26.6 and an iPhone 17 Pro simulator on iOS 26.5.

| Suite | Command | Result |
|---|---|---|
| iOS unit tests (XCTest) | `xcodebuild test -scheme TriviaClash` | **54 passed, 0 failed** |
| Question validator + tooling | `python3 -m unittest scripts/test_questions.py` | **11 passed** |
| Question bank validation | `python3 scripts/questions.py validate` | **1,000 questions, 0 problems** |
| Bundle up to date | `python3 scripts/questions.py check-bundle` | passed |
| Source links | `python3 scripts/check_sources.py` | **955/955** Wikipedia articles exist (one bad link found and fixed) |
| Release build | archive → App Store export → signature/profile verification | passed (signed IPA, Team Store profile) |

### iOS test coverage

| Suite | What it covers |
|---|---|
| `ScoringTests` (6) | Base, speed formula and flooring, clamping, wrong answers, streak cap, double-points multiplier |
| `AnswerOrderTests` (3) | Per-player permutations are valid, deterministic, and vary across rounds and players |
| `RoomCodeTests` (2) | Unambiguous alphabet; input normalisation |
| `MatchEngineTests` (24) | Full flow and early close; the deadline boundary (9,999 ms accepted, 10,000 ms rejected); first answer final and duplicates not double-scored; future and past rounds; invalid choice and non-member; streak reset on timeout; streak bonus; match completion and final double; late observer still gets a full window; reconnect doesn't extend the timer or allow a second answer; no mid-match joins but members can rejoin; answers hidden before close and no score leak; reveal mapped to each player's own order; leaving closes the round when the rest have answered; host hand-over and closing an empty room; host-only start and settings plus readiness; minimum players and the 12-player cap; duplicate names; shared-rank ties; time tie-breaker; solo reveal skip; rematch reset and no repeat questions; not-enough-questions error |
| `TeamTests` (6) | Auto-balance, anti-stacking, teams locked after start, empty-team guard, average scoring with consistent totals, tied teams |
| `QuestionBankTests` (7) | The shipped bundle decrypts with ≥ 1,000 valid, unique questions; every category × difficulty has enough questions; answer positions vary; a tampered bundle is rejected; pick filters; unseen-first and no duplicates; category spread |
| `WireProtocolTests` (3) | Message round-trips; a state message has no answer before close; garbage is ignored |
| `ClockSyncTests` (2) | Host deadline mapped to the local monotonic clock with latency compensation; stale views ignored |
| `ProfileTests` (1) | Name cleaning, length and blocklist |

## Not yet tested (needs real devices)

These haven't been run. CI has no camera, no second device and no human:

- [ ] A nearby match across two or more physical iPhones: discovery, invite by code, lobby sync, synchronised questions, answer submission, reveal, final results
- [ ] Guest disconnect and reconnect mid-question (Wi-Fi off and on)
- [ ] Host backgrounding (expected: guests eventually see "Lost connection to the host")
- [ ] The Local Network permission prompt flow on first use
- [ ] Visual review of every screen at small (iPhone SE) and large sizes, with Dynamic Type at its largest, in dark and light mode, with VoiceOver, and with Reduce Motion
- [ ] Sound and haptics on device

Suggested TestFlight checklist: play one solo game of each length, then a 3-phone free-for-all and a 4-phone team battle. During a question, toggle airplane mode on one guest for 5 seconds and confirm the countdown doesn't reset and the guest's earlier answer is kept.
