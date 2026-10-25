# Trivia Clash

A fast, original trivia party game for iPhone. Every question has a strict **10-second** window, which leaves little time to look an answer up. Play solo, or host a game that friends nearby join from their own phones with a 5-letter room code: free-for-all or team battle, up to 12 players.

| | |
|---|---|
| Platform | iPhone, iOS 17+, SwiftUI |
| Modes | Solo (offline) · Nearby free-for-all · Nearby team battle |
| Questions | 4,909 original questions in 16 categories, at least 300 each ([stats](docs/QUESTION_STATS.md)) |
| Multiplayer | Apple Multipeer Connectivity (Wi-Fi / Bluetooth, encrypted). The host's phone is the referee |
| Online play | Supabase backend designed and partly deployed; not yet enabled in the app ([status](docs/BACKEND.md)) |

## What's in the box

- **One rules engine for every mode** (`ios/TriviaClash/Engine/MatchEngine.swift`). It owns deadlines, answers and scores. Solo runs it on your phone; in nearby play it runs on the host's phone, and every other phone only receives its own filtered view.
- **Strict 10-second timer**, measured on a monotonic clock that ignores wall-clock changes. Answers are timestamped by the referee when they arrive, and an answer arriving at or after the deadline scores nothing. Reconnecting never adds time.
- **Answers stay hidden** until a round closes. Each player sees the four options in a different order. Scores are only applied when the round closes, so nobody can infer correctness mid-round. The first answer is final.
- **Scoring**: 1,000 for a correct answer, up to +250 for speed, +50 per answer in a streak (max +200), and an optional ×2 final question. Details in [docs/SCORING.md](docs/SCORING.md).
- **Lobby**: room code, QR code (`triviaclash://join?code=…`), share sheet, ready-up, host controls, team picker with anti-stacking, host hand-over, kick.
- **Results**: per-question reveal with explanation and source, live standings, final podium, accuracy, fastest answer, best streak, team contributions, rematch.
- **Polish**: dark and light appearance, Dynamic Type, VoiceOver labels, Reduce Motion support, original sound effects and haptics (each can be turned off).
- **Privacy**: guest identity only, no accounts, ads or tracking. All data stays on the device.

## Repository layout

```
ios/                 SwiftUI app (XcodeGen spec in ios/project.yml) and unit tests
questions/           question bank source (one JSON file per category)
scripts/             question validator/builder, asset generator, App Store Connect helper
database/            Supabase schema, engine and API migrations + generated seed (online mode)
docs/                architecture, scoring, anti-cheat, testing, release and App Store notes
.github/workflows/   CI: question validation; iOS test → archive → IPA → TestFlight → GitHub release
```

## Build and run (Mac with Xcode 26)

```bash
brew install xcodegen
cd ios && xcodegen generate && open TriviaClash.xcodeproj
```

Select the **TriviaClash** scheme and an iPhone simulator, then press Run. Nearby multiplayer needs two real devices, or one device plus a simulator, on the same network.

Run the tests with ⌘U in Xcode, or:

```bash
xcodebuild test -project ios/TriviaClash.xcodeproj -scheme TriviaClash -destination 'platform=iOS Simulator,name=iPhone 17'
python3 -m unittest scripts/test_questions.py   # question-bank tooling
```

## Editing questions

Questions live in `questions/<category>.json` as compact rows: `[difficulty, prompt, correct, wrong1, wrong2, wrong3, explanation, source]`. After editing, run:

```bash
pip install cryptography
python3 scripts/questions.py build    # validates, then writes the encrypted app bundle + SQL seed + stats
```

See [docs/QUESTIONS.md](docs/QUESTIONS.md) for the quality rules the validator enforces.

## Releases

Every push to `main` that touches the app runs `.github/workflows/ios.yml` on a macOS runner. It:

1. runs the unit tests
2. archives with automatic signing using the App Store Connect API key
3. exports an App Store Connect IPA and verifies it
4. uploads the IPA to TestFlight
5. attaches the IPA to a GitHub pre-release

Required repository secrets: `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`. See [docs/RELEASE.md](docs/RELEASE.md).

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Scoring](docs/SCORING.md)
- [Fair play and anti-cheat](docs/ANTI_CHEAT.md)
- [Testing](docs/TESTING.md)
- [Questions](docs/QUESTIONS.md)
- [Online backend (Supabase)](docs/BACKEND.md)
- [Release and TestFlight](docs/RELEASE.md)
- [App Store submission kit](docs/APP_STORE.md)
