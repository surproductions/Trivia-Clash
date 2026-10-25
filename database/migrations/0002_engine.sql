-- Trivia Clash: private engine helpers (not callable by clients).
-- Locking rule used everywhere: a writer locks the room row FIRST, then touches
-- members/rounds/answers. This serialises all state changes per room and avoids
-- deadlocks between pollers and answer submissions.

-- Milliseconds since the Unix epoch (what the client receives for all times).
create or replace function tc_private.ms(t timestamptz) returns bigint
language sql immutable as $$ select (extract(epoch from t) * 1000)::bigint $$;

-- Resolve a session token to a player id, or fail.
create or replace function tc_private.session(p_token text) returns uuid
language plpgsql stable
set search_path = tc_private, extensions, pg_temp as $$
declare v uuid;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_session' using errcode = 'P0001';
  end if;
  select id into v from tc_private.players where token_hash = extensions.digest(p_token, 'sha256');
  if v is null then
    raise exception 'invalid_session' using errcode = 'P0001';
  end if;
  return v;
end $$;

-- Fixed-window rate limiter. Raises `rate_limited` when exceeded.
create or replace function tc_private.rate(p_key text, p_max int, p_window_s int) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare
  v_start timestamptz := to_timestamp(floor(extract(epoch from clock_timestamp()) / p_window_s) * p_window_s);
  v_hits int;
begin
  insert into tc_private.rate_hits as h (key, window_start, hits) values (p_key, v_start, 1)
  on conflict (key, window_start) do update set hits = h.hits + 1
  returning hits into v_hits;
  if v_hits > p_max then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
end $$;

-- Best-effort caller IP from PostgREST request headers (for guest sign-up limits).
create or replace function tc_private.client_ip() returns text
language plpgsql stable as $$
declare h json;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    h := null;
  end;
  return coalesce(nullif(trim(split_part(h ->> 'x-forwarded-for', ',', 1)), ''), h ->> 'cf-connecting-ip', 'local');
end $$;

-- Display name sanitiser: trims, collapses whitespace, strips control chars,
-- enforces 2–16 visible characters and a small blocklist.
create or replace function tc_private.clean_name(p_name text) returns text
language plpgsql immutable as $$
declare v text;
begin
  v := regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g');
  v := regexp_replace(trim(v), '\s+', ' ', 'g');
  if char_length(v) < 2 or char_length(v) > 16 then
    raise exception 'invalid_name' using errcode = 'P0001';
  end if;
  if lower(v) ~ '(fuck|shit|cunt|nigg|fag|bitch|whore|slut|rape|nazi|hitler|kike|spic|chink|retard)' then
    raise exception 'name_not_allowed' using errcode = 'P0001';
  end if;
  return v;
end $$;

-- Per-player answer order for a round. Every player sees the four options in
-- a different, deterministic order derived from the round's secret seed.
-- Returns display position -> original option index (0-based values).
create or replace function tc_private.perm(p_seed bytea, p_player uuid) returns smallint[]
language sql immutable
set search_path = tc_private, extensions, pg_temp as $$
  select array_agg(i::smallint order by extensions.digest(p_seed || uuid_send(p_player) || int2send(i::smallint), 'sha256'))
  from generate_series(0, 3) as i
$$;

-- Scoring rules (documented in docs/SCORING.md):
--   correct answer   1000
--   speed bonus      floor(250 * remaining_ms / 10000), remaining measured on the server
--   streak bonus     50 per previous consecutive correct answer, capped at 200
--   multiplier       x2 on the optional final "double points" question
--   wrong / no answer 0 and the streak resets
create or replace function tc_private.score(p_correct boolean, p_remaining_ms int, p_streak_before int, p_multiplier int)
returns table (base int, speed int, streak_bonus int, total int)
language sql immutable as $$
  select b, s, k, (b + s + k) * greatest(least(p_multiplier, 2), 1)
  from (select
          case when p_correct then 1000 else 0 end as b,
          case when p_correct then floor(250.0 * least(greatest(p_remaining_ms, 0), 10000) / 10000)::int else 0 end as s,
          case when p_correct then least(greatest(p_streak_before, 0), 4) * 50 else 0 end as k) x
$$;

-- Increment the room version and nudge realtime subscribers. The payload carries
-- only the version number; clients then fetch their own filtered state.
create or replace function tc_private.bump(p_room uuid) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare v bigint;
begin
  update tc_private.rooms set version = version + 1, last_activity_at = now()
  where id = p_room returning version into v;
  begin
    perform realtime.send(jsonb_build_object('v', v), 'state', 'tc-room-' || p_room::text, false);
  exception when others then
    null; -- realtime is an optimisation; polling remains authoritative
  end;
end $$;

create or replace function tc_private.gen_code() returns text
language plpgsql
set search_path = tc_private, extensions, pg_temp as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- no O/0, I/1/L
  b bytea;
  v text;
  attempt int := 0;
begin
  loop
    attempt := attempt + 1;
    b := extensions.gen_random_bytes(5);
    v := '';
    for i in 0..4 loop
      v := v || substr(alphabet, 1 + (get_byte(b, i) % 31), 1);
    end loop;
    exit when not exists (select 1 from tc_private.rooms where code = v and status <> 'closed');
    if attempt > 25 then
      raise exception 'code_space_exhausted' using errcode = 'P0001';
    end if;
  end loop;
  return v;
end $$;

-- Pick a nickname that is unique among active members of a room ("Sam" -> "Sam 2").
create or replace function tc_private.unique_nick(p_room uuid, p_name text, p_player uuid) returns text
language plpgsql
set search_path = tc_private, pg_temp as $$
declare v text := p_name; n int := 1;
begin
  while exists (select 1 from tc_private.members
                where room_id = p_room and left_at is null and player_id <> p_player
                  and lower(nickname) = lower(v)) loop
    n := n + 1;
    v := left(p_name, 13) || ' ' || n;
  end loop;
  return v;
end $$;

create or replace function tc_private.apply_settings(p_room uuid, s jsonb) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare
  valid_cats constant text[] := array['general','science','history','geography','sports','screen','music',
    'games','tech','food','arts','animals','space','mythology','popculture','math'];
  v_count int;
  v_cats text[];
  v_diff text;
  v_teams int;
begin
  if s is null then return; end if;
  if s ? 'question_count' then
    v_count := (s ->> 'question_count')::int;
    if v_count not in (5, 10, 15, 20, 30) then
      raise exception 'invalid_settings' using errcode = 'P0001';
    end if;
    update tc_private.rooms set question_count = v_count where id = p_room;
  end if;
  if s ? 'categories' then
    select coalesce(array_agg(distinct c), '{}') into v_cats
    from jsonb_array_elements_text(s -> 'categories') c where c = any(valid_cats);
    update tc_private.rooms set categories = v_cats where id = p_room;
  end if;
  if s ? 'difficulty' then
    v_diff := s ->> 'difficulty';
    if v_diff not in ('easy','medium','hard','mixed') then
      raise exception 'invalid_settings' using errcode = 'P0001';
    end if;
    update tc_private.rooms set difficulty = v_diff where id = p_room;
  end if;
  if s ? 'team_count' then
    v_teams := (s ->> 'team_count')::int;
    if v_teams < 2 or v_teams > 4 then
      raise exception 'invalid_settings' using errcode = 'P0001';
    end if;
    update tc_private.rooms set team_count = v_teams where id = p_room;
    update tc_private.members set team = null where room_id = p_room and team >= v_teams;
  end if;
  if s ? 'final_double' then
    update tc_private.rooms set final_double = coalesce((s ->> 'final_double')::boolean, false) where id = p_room;
  end if;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'invalid_settings' using errcode = 'P0001';
end $$;

-- Put every active, team-less member on the currently smallest team.
create or replace function tc_private.fill_teams(p_room uuid) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare m record; v_team int; v_count smallint;
begin
  select team_count into v_count from tc_private.rooms where id = p_room;
  for m in select player_id from tc_private.members
           where room_id = p_room and left_at is null and team is null order by joined_at loop
    select g.t into v_team
    from generate_series(0, v_count - 1) g(t)
    left join tc_private.members x on x.room_id = p_room and x.left_at is null and x.team = g.t
    group by g.t order by count(x.player_id), g.t limit 1;
    update tc_private.members set team = v_team where room_id = p_room and player_id = m.player_id;
  end loop;
end $$;

-- Hand the host role to the longest-present connected member (or close the room).
create or replace function tc_private.reassign_host(p_room uuid) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare v uuid;
begin
  select player_id into v from tc_private.members
  where room_id = p_room and left_at is null
  order by (last_seen_at > clock_timestamp() - interval '10 seconds') desc, joined_at
  limit 1;
  if v is null then
    update tc_private.rooms set host_id = null, status = 'closed', phase_ends_at = null where id = p_room;
  else
    update tc_private.rooms set host_id = v where id = p_room;
  end if;
end $$;

-- Open round `p_round` at time `p_at`. The 10-second window is fixed here, once,
-- by the server; nothing a client does later can move it.
create or replace function tc_private.open_round(p_room uuid, p_round int, p_at timestamptz) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare v_rid uuid; v_closes timestamptz := p_at + interval '10 seconds';
begin
  update tc_private.rounds rd set opens_at = p_at, closes_at = v_closes
  from tc_private.rooms r
  where r.id = p_room and rd.room_id = r.id and rd.match_no = r.match_no and rd.round_no = p_round
  returning rd.id into v_rid;
  update tc_private.rooms set status = 'question', current_round = p_round, phase_ends_at = v_closes
  where id = p_room;
  insert into tc_private.seen (player_id, question_id, seen_at)
  select m.player_id, rd.question_id, p_at
  from tc_private.members m join tc_private.rounds rd on rd.id = v_rid
  where m.room_id = p_room and m.left_at is null
  on conflict (player_id, question_id) do update set seen_at = excluded.seen_at;
end $$;

-- Close the current round: apply the hidden per-answer scores to members,
-- break streaks of anyone who did not answer, and move to the reveal phase.
create or replace function tc_private.close_round(p_room uuid, p_at timestamptz) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare v_rid uuid; v_closed timestamptz; v_mode text;
begin
  select rd.id, rd.closed_at, r.mode into v_rid, v_closed, v_mode
  from tc_private.rooms r
  join tc_private.rounds rd on rd.room_id = r.id and rd.match_no = r.match_no and rd.round_no = r.current_round
  where r.id = p_room;
  if v_rid is null or v_closed is not null then return; end if;

  update tc_private.rounds set closed_at = p_at where id = v_rid;

  update tc_private.members m set
    score        = m.score + a.points,
    correct      = m.correct + a.is_correct::int,
    answered     = m.answered + 1,
    streak       = case when a.is_correct then m.streak + 1 else 0 end,
    best_streak  = greatest(m.best_streak, case when a.is_correct then m.streak + 1 else 0 end),
    correct_ms   = m.correct_ms + case when a.is_correct then a.response_ms else 0 end,
    fastest_ms   = case when a.is_correct then least(coalesce(m.fastest_ms, a.response_ms), a.response_ms) else m.fastest_ms end,
    last_points  = a.points,
    last_correct = a.is_correct
  from tc_private.answers a
  where a.round_id = v_rid and a.player_id = m.player_id and m.room_id = p_room;

  update tc_private.members m set streak = 0, last_points = 0, last_correct = null
  where m.room_id = p_room
    and not exists (select 1 from tc_private.answers a where a.round_id = v_rid and a.player_id = m.player_id);

  update tc_private.rooms set status = 'reveal',
    phase_ends_at = p_at + case when v_mode = 'solo' then interval '90 seconds' else interval '7 seconds' end
  where id = p_room;
end $$;

create or replace function tc_private.standings(p_room uuid) returns jsonb
language sql stable
set search_path = tc_private, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', player_id, 'name', nickname, 'team', team, 'score', score, 'correct', correct,
           'answered', answered, 'best_streak', best_streak, 'fastest_ms', fastest_ms, 'rank', rnk)
         order by ord), '[]'::jsonb)
  from (select m.*,
          rank() over (order by score desc, correct desc, correct_ms asc) as rnk,
          row_number() over (order by score desc, correct desc, correct_ms asc, joined_at asc) as ord
        from tc_private.members m where m.room_id = p_room) x
$$;

-- Team score = average points per team member (rounded), so uneven team sizes
-- stay fair. Ties: total correct answers, then team index.
create or replace function tc_private.team_standings(p_room uuid, p_include_left boolean) returns jsonb
language sql stable
set search_path = tc_private, pg_temp as $$
  with t as (
    select g.t as idx,
           count(m.player_id) as size,
           coalesce(sum(m.score), 0) as total,
           coalesce(sum(m.correct), 0) as correct,
           case when count(m.player_id) > 0 then round(sum(m.score)::numeric / count(m.player_id))::int else 0 end as score
    from tc_private.rooms r
    cross join generate_series(0, r.team_count - 1) g(t)
    left join tc_private.members m on m.room_id = r.id and m.team = g.t and (p_include_left or m.left_at is null)
    where r.id = p_room
    group by g.t
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'index', idx, 'size', size, 'score', score, 'total', total, 'correct', correct, 'rank', rnk)
         order by rnk, idx), '[]'::jsonb)
  from (select t.*, rank() over (order by score desc, correct desc) as rnk from t) ranked
$$;

create or replace function tc_private.finish(p_room uuid) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare r tc_private.rooms;
begin
  update tc_private.rooms set status = 'finished', phase_ends_at = null where id = p_room returning * into r;
  insert into tc_private.match_results (room_id, match_no, mode, standings, teams)
  values (p_room, r.match_no, r.mode, tc_private.standings(p_room),
          case when r.mode = 'teams' then tc_private.team_standings(p_room, true) end);
end $$;

-- Advance any phases whose deadline has passed. Caller must hold the room lock.
-- Phases are scheduled from stored deadlines (not from when someone happened to
-- poll), so lazy evaluation never stretches a question window.
create or replace function tc_private.advance(p_room uuid) returns boolean
language plpgsql
set search_path = tc_private, pg_temp as $$
declare
  r tc_private.rooms;
  v_now timestamptz := clock_timestamp();
  v_at timestamptz;
  v_changed boolean := false;
  i int := 0;
begin
  loop
    select * into r from tc_private.rooms where id = p_room;
    exit when r.phase_ends_at is null or r.phase_ends_at > v_now or i >= 6;
    i := i + 1;
    v_changed := true;
    -- If nobody was around to observe a phase change for a while, start the next
    -- question "now" rather than in the past, so players still get 10 seconds.
    v_at := case when v_now - r.phase_ends_at < interval '1500 milliseconds' then r.phase_ends_at else v_now end;
    if r.status = 'countdown' then
      perform tc_private.open_round(p_room, 1, v_at);
    elsif r.status = 'question' then
      perform tc_private.close_round(p_room, r.phase_ends_at);
    elsif r.status = 'reveal' then
      if r.current_round >= r.total_rounds then
        perform tc_private.finish(p_room);
      else
        perform tc_private.open_round(p_room, r.current_round + 1, v_at);
      end if;
    else
      update tc_private.rooms set phase_ends_at = null where id = p_room;
    end if;
  end loop;
  if v_changed then
    perform tc_private.bump(p_room);
  end if;
  return v_changed;
end $$;

-- Start a match: reset scores, select questions server-side, schedule countdown.
create or replace function tc_private.start_match(p_room uuid) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare
  r tc_private.rooms;
  v_n int;
  v_empty int;
begin
  select * into r from tc_private.rooms where id = p_room;

  if r.mode = 'teams' then
    perform tc_private.fill_teams(p_room);
    select count(*) into v_empty
    from generate_series(0, r.team_count - 1) g(t)
    where not exists (select 1 from tc_private.members m
                      where m.room_id = p_room and m.left_at is null and m.team = g.t);
    if v_empty > 0 then
      raise exception 'team_empty' using errcode = 'P0001';
    end if;
  end if;

  delete from tc_private.members where room_id = p_room and left_at is not null;
  update tc_private.members set score = 0, correct = 0, answered = 0, streak = 0, best_streak = 0,
    correct_ms = 0, fastest_ms = null, last_points = 0, last_correct = null
  where room_id = p_room;
  delete from tc_private.rounds where room_id = p_room;

  update tc_private.rooms set match_no = match_no + 1 where id = p_room returning * into r;

  -- Unseen questions first (random order), then the least recently seen.
  with pool as (
    select q.id,
           (select max(s.seen_at) from tc_private.seen s
             join tc_private.members m on m.player_id = s.player_id and m.room_id = p_room and m.left_at is null
             where s.question_id = q.id) as last_seen
    from tc_private.questions q
    where q.review_status = 'approved'
      and (cardinality(r.categories) = 0 or q.category = any(r.categories))
      and (r.difficulty = 'mixed' or q.difficulty = r.difficulty)
  ), picked as (
    select id, row_number() over (order by coalesce(last_seen, '-infinity'::timestamptz), random()) as n
    from pool
  )
  insert into tc_private.rounds (room_id, match_no, round_no, question_id)
  select p_room, r.match_no, n, id from picked where n <= r.question_count;
  get diagnostics v_n = row_count;

  if v_n < 3 then
    raise exception 'not_enough_questions' using errcode = 'P0001';
  end if;
  if r.final_double then
    update tc_private.rounds set multiplier = 2
    where room_id = p_room and match_no = r.match_no and round_no = v_n;
  end if;

  update tc_private.rooms set status = 'countdown', current_round = 0, total_rounds = v_n,
    phase_ends_at = clock_timestamp() + interval '3500 milliseconds'
  where id = p_room;
end $$;

-- Build the state document for one player. Before a round closes this contains
-- the question and *that player's* option order only — never the answer.
create or replace function tc_private.state_json(p_room uuid, p_me uuid) returns jsonb
language plpgsql volatile
set search_path = tc_private, pg_temp as $$
declare
  r tc_private.rooms;
  rd tc_private.rounds;
  q tc_private.questions;
  a tc_private.answers;
  v_perm smallint[];
  v_round jsonb;
  v_reveal jsonb;
  v_members jsonb;
  v_teams jsonb;
  v_now timestamptz := clock_timestamp();
  v_rid uuid;
begin
  select * into r from tc_private.rooms where id = p_room;

  if r.status in ('question', 'reveal', 'finished') and r.current_round > 0 then
    select * into rd from tc_private.rounds
    where room_id = p_room and match_no = r.match_no and round_no = r.current_round;
    v_rid := rd.id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.player_id, 'name', x.nickname, 'avatar', x.avatar, 'team', x.team,
      'ready', x.is_ready, 'host', x.player_id = r.host_id,
      'connected', x.last_seen_at > v_now - interval '10 seconds',
      'left', x.left_at is not null,
      'score', x.score, 'correct', x.correct, 'answered', x.answered,
      'streak', x.streak, 'best_streak', x.best_streak, 'fastest_ms', x.fastest_ms,
      'avg_ms', case when x.correct > 0 then x.correct_ms / x.correct end,
      'last_points', x.last_points, 'last_correct', x.last_correct,
      'rank', x.rnk,
      'locked_in', r.status = 'question' and exists (
          select 1 from tc_private.answers aa where aa.round_id = v_rid and aa.player_id = x.player_id))
    order by x.ord), '[]'::jsonb)
  into v_members
  from (select m.*,
          rank() over (order by m.score desc, m.correct desc, m.correct_ms asc) as rnk,
          row_number() over (order by m.score desc, m.correct desc, m.correct_ms asc, m.joined_at asc) as ord
        from tc_private.members m
        where m.room_id = p_room and (m.left_at is null or r.status not in ('lobby'))) x;

  if r.mode = 'teams' then
    v_teams := tc_private.team_standings(p_room, r.status <> 'lobby');
  end if;

  if v_rid is not null and rd.opens_at is not null then
    select * into q from tc_private.questions where id = rd.question_id;
    select * into a from tc_private.answers where round_id = rd.id and player_id = p_me;
    v_perm := tc_private.perm(rd.seed, p_me);
    v_round := jsonb_build_object(
      'no', rd.round_no, 'total', r.total_rounds,
      'category', q.category, 'difficulty', q.difficulty, 'prompt', q.prompt,
      'options', (select jsonb_agg(q.options[v_perm[k] + 1] order by k) from generate_series(1, 4) k),
      'opens_at', tc_private.ms(rd.opens_at), 'closes_at', tc_private.ms(rd.closes_at),
      'multiplier', rd.multiplier,
      'answered_count', (select count(*) from tc_private.answers x where x.round_id = rd.id),
      'my_choice', a.shown_choice,
      'closed', rd.closed_at is not null);
    if rd.closed_at is not null then
      v_reveal := jsonb_build_object(
        'correct_choice', array_position(v_perm, q.correct_index) - 1,
        'explanation', q.explanation,
        'source', q.source,
        'my', case when a.player_id is null then null else jsonb_build_object(
                'correct', a.is_correct, 'points', a.points, 'base', a.base_points,
                'speed', a.speed_bonus, 'streak_bonus', a.streak_bonus, 'response_ms', a.response_ms) end,
        'distribution', (select jsonb_agg((select count(*) from tc_private.answers x
                                            where x.round_id = rd.id and x.choice = v_perm[k]) order by k)
                         from generate_series(1, 4) k));
    end if;
  end if;

  return jsonb_build_object(
    'server_now', tc_private.ms(clock_timestamp()),
    'version', r.version,
    'me', p_me,
    'room', jsonb_build_object(
      'id', r.id, 'code', r.code, 'mode', r.mode, 'status', r.status, 'host_id', r.host_id,
      'question_count', r.question_count, 'total_rounds', r.total_rounds,
      'categories', to_jsonb(r.categories), 'difficulty', r.difficulty,
      'team_count', r.team_count, 'final_double', r.final_double,
      'match_no', r.match_no, 'current_round', r.current_round,
      'phase_ends_at', tc_private.ms(r.phase_ends_at), 'max_players', 12),
    'members', v_members,
    'teams', v_teams,
    'round', v_round,
    'reveal', v_reveal);
end $$;

-- Remove a member from a room (shared by leave, kick and account deletion).
create or replace function tc_private.remove_member(p_room uuid, p_player uuid) returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
declare r tc_private.rooms;
begin
  select * into r from tc_private.rooms where id = p_room;
  if r.mode = 'solo' then
    update tc_private.rooms set status = 'closed', phase_ends_at = null where id = p_room;
  elsif r.status in ('lobby', 'finished') then
    delete from tc_private.members where room_id = p_room and player_id = p_player;
  else
    update tc_private.members set left_at = clock_timestamp(), is_ready = false
    where room_id = p_room and player_id = p_player;
    -- If everyone still playing has already answered, close the round now.
    if r.status = 'question' and not exists (
        select 1 from tc_private.members m
        where m.room_id = p_room and m.left_at is null
          and not exists (select 1 from tc_private.answers a
                          join tc_private.rounds rd on rd.id = a.round_id
                          where rd.room_id = p_room and rd.match_no = r.match_no
                            and rd.round_no = r.current_round and a.player_id = m.player_id))
       and exists (select 1 from tc_private.members m where m.room_id = p_room and m.left_at is null) then
      perform tc_private.close_round(p_room, clock_timestamp());
    end if;
  end if;
  if r.host_id = p_player and r.mode <> 'solo' then
    perform tc_private.reassign_host(p_room);
  end if;
  if r.mode <> 'solo' and not exists (select 1 from tc_private.members where room_id = p_room and left_at is null) then
    update tc_private.rooms set status = 'closed', phase_ends_at = null where id = p_room;
  end if;
end $$;
