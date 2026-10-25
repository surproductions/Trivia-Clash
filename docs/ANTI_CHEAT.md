# Fair play and anti-cheat

The 10-second window is a core rule, not a cosmetic timer. These protections make looking answers up slow and unrewarding without being invasive. No camera, microphone, photo, contacts, location or screen access is requested.

## What is implemented

| Protection | How |
|---|---|
| Authoritative deadline | Each round's `opensAt` and `closesAt` are fixed once by the authority (solo device or host). Clients only render a countdown derived from them. |
| Late answers rejected | Acceptance requires `opensAt ≤ receiveTime < closesAt` on the authority's monotonic clock. A client-supplied timestamp is never used. |
| Clock tampering ignored | Monotonic clock (`CLOCK_MONOTONIC`): changing the device time has no effect, and backgrounding or sleep doesn't pause it. |
| No answer before close | Guests receive only the prompt, their own option order, the round number and the deadlines. The correct position, explanation and per-option counts arrive only after the round closes. |
| Per-player answer order | Each player's options are shuffled with a per-round secret seed and their player id, so "it's B!" doesn't help a friend. |
| First answer is final | One stored answer per player per round. Retries and replays return the original answer. |
| No correctness leaks | Scores and streaks update only when a round closes; mid-round, others see only who has locked in. |
| Server-side scoring | Correctness and points are computed by the authority. A guest can't send a score, speed or "correct" flag; the protocol has no field for it. |
| Reconnects grant nothing | Rejoining restores the seat and existing answer. Deadlines don't move. |
| Question rotation | Recently seen questions (last 600 per device, plus those reported by each player who joins) are avoided. Selection is random, interleaves categories and happens on the authority. |
| Room access | 5-character codes from a 31-symbol alphabet. The host only admits peers presenting the matching code over an encrypted Multipeer session. Room size is capped at 12. The host can remove players. |
| Answer key not in plain text | The bundled question set is AES-GCM encrypted and decrypted in memory. |
| Spam protection | Guest requests are ignored unless they come from a mapped peer. Submissions are idempotent, and an out-of-range choice is rejected. |

## Known limitations

- **No system can stop a second device or a friend.** A determined player can photograph a question and search on another phone. Ten seconds makes that hard, and the speed bonus makes it costly, but not impossible.
- **The host is the referee in nearby play.** A modified host app could cheat for itself. Nearby play is meant for friends in the same room. The online backend (see BACKEND.md) moves authority to a database for public play.
- **The bundle key ships inside the app.** Encrypting the bundle keeps answers out of plain sight, but someone who reverse-engineers the binary could extract them. In solo play only that player is affected. In nearby play, guests never need the answers.
- **Network delay.** Guests on Wi-Fi or Bluetooth typically see 5–50 ms of latency. Answers are judged on arrival at the host, so a guest who taps at the last instant on a slow link can be marked late. Guests measure the round-trip time and end their on-screen countdown one round trip early, so a tap made before the display reaches zero still arrives in time.

## Online backend (designed)

`database/migrations/0001–0003` add server-only enforcement for the online mode:

- private schema, RLS on every table, no direct table access
- hashed guest session tokens
- per-IP and per-player rate limits on sign-up, room creation, joining, lobby actions, state polling and submissions
- a composite primary key that makes duplicate answers impossible
- row locks that serialise submissions with round closing
