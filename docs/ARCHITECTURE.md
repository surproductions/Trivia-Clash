# Architecture

## Overview

```
┌──────────────────────────── iPhone (host or solo) ────────────────────────────┐
│ SwiftUI views ──► GameSession (ObservableObject) ──► MatchEngine (authority)   │
│                       ▲            │ per-player PlayerView                     │
│                       │            ▼                                           │
│                 NearbyHostSession ── MultipeerConnectivity (encrypted) ──┐     │
└──────────────────────────────────────────────────────────────────────────┼─────┘
                                                                           │
┌──────────────────────────── iPhone (guest) ───────────────────────────── ▼ ───┐
│ SwiftUI views ──► NearbyGuestSession ── sends requests, renders host views     │
└────────────────────────────────────────────────────────────────────────────────┘
```

| Layer | Files | Responsibility |
|---|---|---|
| Engine | `Engine/MatchEngine.swift`, `Scoring.swift`, `QuestionBank.swift`, `Models.swift` | Pure, deterministic game rules. All time values are passed in, so they are fully unit-tested. |
| Session | `Session/GameSession.swift`, `Session/Nearby.swift` | Connects the UI to an engine: `SoloSession`, `NearbyHostSession` (engine runs locally and broadcasts views) and `NearbyGuestSession` (remote engine). |
| Services | `Services/Services.swift` | Monotonic clock, local persistence (profile, settings, stats, seen questions), sound, haptics. |
| Design | `Design/Theme.swift`, `Design/Components.swift` | Colour tokens (dark and light), typography and reusable components. |
| Features | `Features/*.swift` | Screens: onboarding, home, setup, join, lobby, countdown, question, reveal, results, settings, profile. |

The UI is MVVM-style: views observe a `GameSession`, which publishes a `PlayerView`, an immutable snapshot of what *this* player is allowed to see. Phases (`lobby → countdown → question → reveal → … → finished`) drive navigation in `GameContainerView`.

## The match engine

`MatchEngine` is a state machine:

- `join` / `leave` / `setReady` / `setTeam` / `shuffleTeams` / `kick` / `updateSettings` handle the lobby, with host-only checks.
- `start` selects questions (unseen first, categories interleaved), schedules a 3.5 s countdown and resets scores.
- `tick(now:)` advances overdue phases. Phases are scheduled from stored deadlines, never from when someone happened to look. If no one advanced the match for more than 1.5 s after a phase ended, the next question starts "now", so it still gets its full 10 seconds.
- `submit(playerId:round:choice:now:)` accepts the first answer when `opensAt ≤ now < closesAt`, maps the displayed position back to the original option, and stores a hidden score breakdown. When every active player has answered, the round closes early.
- Scores, streaks and stats are applied only when a round closes.
- `view(for:now:)` builds the per-player `PlayerView`.

## Time

All deadlines use `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, which counts through device sleep and ignores wall-clock changes.

- **Solo:** the engine and the UI share one clock.
- **Nearby:** guests receive `serverNow` plus deadlines in the host's clock. A guest maps them onto its own monotonic clock using the time a view arrived, shifted by two estimated one-way latencies (ping/pong every 2 s, smoothed). One covers the view arriving and one covers the answer travelling back, so a tap before the local countdown reaches zero still arrives in time. That estimate only affects how the countdown is drawn. Acceptance is always decided by the host's clock when the answer arrives.

## Nearby networking

- Service type `tclash` over Bonjour (`_tclash._tcp` / `_tclash._udp`), with `MCSession` `encryptionPreference: .required`.
- The host advertises `{code, host, v}`. Guests must present the matching room code in the invitation context or the host declines.
- Messages are `Codable` enums (`ClientMessage`, `HostMessage`) encoded as JSON. The host sends each guest **only that guest's** `PlayerView`.
- **Reconnect:** a guest that drops keeps browsing for the same code and re-sends `hello` with the same player id. The host restores the seat, existing answer and score. Deadlines are unchanged.
- **Limitation:** if the host's phone leaves or is backgrounded long enough for iOS to drop the connection, the game ends for everyone, because the host is the referee. The host screen is kept awake while hosting.

## Online mode (designed, not enabled)

`database/migrations/` contains a complete server-authoritative design for Supabase/PostgreSQL. It uses the same rules, implemented as `SECURITY DEFINER` RPCs over a private schema. See [BACKEND.md](BACKEND.md) for its deployment status. The `PlayerView` model mirrors the server's state document (snake_case ↔ camelCase), so an online `GameSession` subclass can plug into the same UI.
