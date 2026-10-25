-- Trivia Clash: core schema.
-- All game tables live in the private `tc_private` schema, which is NOT exposed
-- through the Supabase Data API. Clients can only reach game state through the
-- SECURITY DEFINER `public.tc_*` RPC functions defined in 0002_functions.sql.

create schema if not exists tc_private;
revoke all on schema tc_private from public;
revoke all on schema tc_private from anon, authenticated;

-- Guest identities. The client holds a random 256-bit token; only its SHA-256
-- hash is stored, so a database leak does not leak usable sessions.
create table tc_private.players (
  id            uuid primary key default gen_random_uuid(),
  token_hash    bytea not null unique,
  display_name  text not null,
  avatar        smallint not null default 0 check (avatar between 0 and 11),
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

-- Question bank. `correct_index` never leaves the server before a round closes.
create table tc_private.questions (
  id             text primary key,
  category       text not null check (category in (
                   'general','science','history','geography','sports','screen',
                   'music','games','tech','food','arts','animals','space',
                   'mythology','popculture','math')),
  difficulty     text not null check (difficulty in ('easy','medium','hard')),
  prompt         text not null check (length(prompt) between 10 and 300),
  options        text[] not null check (array_length(options, 1) = 4),
  correct_index  smallint not null check (correct_index between 0 and 3),
  explanation    text not null check (length(explanation) > 0),
  source         text not null check (length(source) > 0),
  tags           text[] not null default '{}',
  language       text not null default 'en',
  review_status  text not null default 'approved' check (review_status in ('draft','approved','retired')),
  verified_on    date,
  updated_at     timestamptz not null default now()
);
create index questions_pick_idx on tc_private.questions (category, difficulty) where review_status = 'approved';

-- Rooms. `id` is an unguessable UUID used for every call after joining; the
-- 5-character `code` is only a convenience for finding the room.
create table tc_private.rooms (
  id                uuid primary key default gen_random_uuid(),
  code              text not null,
  host_id           uuid references tc_private.players(id) on delete set null,
  mode              text not null check (mode in ('solo','ffa','teams')),
  status            text not null default 'lobby'
                      check (status in ('lobby','countdown','question','reveal','finished','closed')),
  question_count    smallint not null default 10 check (question_count in (5,10,15,20,30)),
  total_rounds      smallint not null default 0,
  categories        text[] not null default '{}',
  difficulty        text not null default 'mixed' check (difficulty in ('easy','medium','hard','mixed')),
  team_count        smallint not null default 2 check (team_count between 2 and 4),
  final_double      boolean not null default false,
  match_no          int not null default 0,
  current_round     smallint not null default 0,
  phase_ends_at     timestamptz,
  version           bigint not null default 1,
  created_at        timestamptz not null default now(),
  last_activity_at  timestamptz not null default now()
);
create unique index rooms_active_code_idx on tc_private.rooms (code) where status <> 'closed';
create index rooms_status_idx on tc_private.rooms (status, last_activity_at);

create table tc_private.members (
  room_id       uuid not null references tc_private.rooms(id) on delete cascade,
  player_id     uuid not null references tc_private.players(id) on delete cascade,
  nickname      text not null,
  avatar        smallint not null default 0,
  team          smallint,
  is_ready      boolean not null default false,
  joined_at     timestamptz not null default clock_timestamp(),
  last_seen_at  timestamptz not null default clock_timestamp(),
  left_at       timestamptz,
  score         int not null default 0 check (score >= 0),
  correct       int not null default 0 check (correct >= 0),
  answered      int not null default 0 check (answered >= 0),
  streak        int not null default 0 check (streak >= 0),
  best_streak   int not null default 0 check (best_streak >= 0),
  correct_ms    bigint not null default 0 check (correct_ms >= 0),
  fastest_ms    int,
  last_points   int not null default 0,
  last_correct  boolean,
  primary key (room_id, player_id)
);
create unique index members_nick_idx on tc_private.members (room_id, lower(nickname)) where left_at is null;
create index members_player_idx on tc_private.members (player_id);

create table tc_private.rounds (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null references tc_private.rooms(id) on delete cascade,
  match_no     int not null,
  round_no     smallint not null,
  question_id  text not null references tc_private.questions(id),
  seed         bytea not null default extensions.gen_random_bytes(16),
  multiplier   smallint not null default 1 check (multiplier in (1,2)),
  opens_at     timestamptz,
  closes_at    timestamptz,
  closed_at    timestamptz,
  unique (room_id, match_no, round_no)
);

-- One row per (round, player): the primary key is what makes a first answer final
-- and duplicate submissions impossible, even under concurrent retries.
create table tc_private.answers (
  round_id      uuid not null references tc_private.rounds(id) on delete cascade,
  player_id     uuid not null references tc_private.players(id) on delete cascade,
  room_id       uuid not null,
  choice        smallint not null check (choice between 0 and 3),
  shown_choice  smallint not null check (shown_choice between 0 and 3),
  received_at   timestamptz not null,
  response_ms   int not null check (response_ms >= 0),
  is_correct    boolean not null,
  base_points   int not null check (base_points >= 0),
  speed_bonus   int not null check (speed_bonus >= 0),
  streak_bonus  int not null check (streak_bonus >= 0),
  points        int not null check (points >= 0),
  primary key (round_id, player_id)
);

-- Recently served questions per player, used to avoid repeats.
create table tc_private.seen (
  player_id    uuid not null references tc_private.players(id) on delete cascade,
  question_id  text not null references tc_private.questions(id) on delete cascade,
  seen_at      timestamptz not null default now(),
  primary key (player_id, question_id)
);

create table tc_private.rate_hits (
  key           text not null,
  window_start  timestamptz not null,
  hits          int not null default 0,
  primary key (key, window_start)
);

create table tc_private.match_results (
  id           uuid primary key default gen_random_uuid(),
  room_id      uuid not null,
  match_no     int not null,
  mode         text not null,
  finished_at  timestamptz not null default now(),
  standings    jsonb not null,
  teams        jsonb
);

-- Defence in depth: even if the schema were exposed by mistake, RLS with no
-- policies denies every row to anon/authenticated.
alter table tc_private.players        enable row level security;
alter table tc_private.questions      enable row level security;
alter table tc_private.rooms          enable row level security;
alter table tc_private.members        enable row level security;
alter table tc_private.rounds         enable row level security;
alter table tc_private.answers        enable row level security;
alter table tc_private.seen           enable row level security;
alter table tc_private.rate_hits      enable row level security;
alter table tc_private.match_results  enable row level security;
