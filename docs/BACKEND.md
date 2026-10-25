# Online backend (Supabase): status and setup

Online room-code play over the internet is **designed but not yet enabled in the app**. The shipped app plays solo offline and multiplayer over the local network only.

## Status

| Item | State |
|---|---|
| `0001_schema.sql`: private schema and tables with RLS | **Applied** to Supabase project `njzdnrwtdffoodthrgox` (schema `tc_private`, tables only, no data) |
| `0002_engine.sql`: game engine functions | Written, **not applied**. Supabase's approval prompt never reached the project owner during the build session. |
| `0003_api.sql`: public `tc_*` RPC API | Written, not applied |
| `0004_maintenance.sql`: 5-minute cleanup cron job | Written, not applied |
| `seed/questions.sql`: 1,000 questions | Generated, not applied |
| iOS online client (`GameSession` subclass using the RPCs) | Not built |

The Supabase project is shared with other apps (`fd_*`, `ph_*`, `pb_*` tables). Everything Trivia Clash adds is isolated in the `tc_private` schema and `public.tc_*` functions.

## Design

- **No direct table access.** All tables live in `tc_private`, which the Data API doesn't expose, and RLS is enabled with no policies. Clients call `SECURITY DEFINER` RPCs only.
- **Guest sessions.** `tc_register` returns a random 256-bit token once and stores only its SHA-256 hash. Every RPC takes the token.
- **Server-authoritative rounds.** `tc_get_state` is the polling and sync call. Under a row lock it advances overdue phases from stored deadlines (the same rules as the iOS engine), records presence and returns the caller's filtered state. `tc_submit_answer` locks the room, timestamps with `clock_timestamp()`, rejects late, duplicate or invalid answers and stores a hidden score that is applied at close.
- **Realtime.** Every change calls `realtime.send` on topic `tc-room-<uuid>` with only a version number. Clients then fetch their own state, and polling is the fallback.
- **Rate limits.** Sign-up per IP; room creation, joins, lobby actions, state polls and submissions per player.
- **Housekeeping.** pg_cron job `tc-maintenance` closes idle rooms (15 minutes without an active player, or 12 hours old), deletes closed rooms after 2 days and purges old rate-limit and history rows.

## To finish online mode

1. In the Supabase dashboard SQL editor, run `database/migrations/0002_engine.sql`, `0003_api.sql` and `0004_maintenance.sql` in that order, then `database/seed/questions.sql`. All of them are idempotent (`create or replace`, `on conflict`).
2. Check the security and performance advisors in the dashboard.
3. Build `OnlineSession: GameSession` in the app. Call the RPCs with the project URL and publishable key (the publishable key is safe to embed), decode state with `.convertFromSnakeCase` into `PlayerView`, poll `tc_get_state` about once a second plus at each `phase_ends_at`, and subscribe to the realtime topic for instant nudges.
4. Add Online host/join entries next to the nearby ones.

## Backups

Supabase takes daily backups on paid plans. Game data is ephemeral (rooms expire within hours), so the only durable content is `tc_private.questions`, which can always be regenerated from `database/seed/questions.sql`.
