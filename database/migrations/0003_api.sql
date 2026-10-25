-- Trivia Clash: public RPC API (exposed through PostgREST as /rest/v1/rpc/tc_*).
-- Every function is SECURITY DEFINER, validates the caller's session token, and
-- treats all arguments as untrusted.

-- Create a guest identity. Returns the session token exactly once.
create or replace function public.tc_register(p_name text, p_avatar int default 0)
returns jsonb language plpgsql security definer
set search_path = tc_private, extensions, pg_temp as $$
declare v_token text; v_name text; v_id uuid;
begin
  perform tc_private.rate('register:' || tc_private.client_ip(), 30, 600);
  v_name := tc_private.clean_name(p_name);
  if p_avatar is null or p_avatar < 0 or p_avatar > 11 then p_avatar := 0; end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into tc_private.players (token_hash, display_name, avatar)
  values (extensions.digest(v_token, 'sha256'), v_name, p_avatar)
  returning id into v_id;
  return jsonb_build_object('token', v_token, 'player_id', v_id, 'name', v_name, 'avatar', p_avatar);
end $$;

-- Profile + the room the player is still part of (used to resume after relaunch).
create or replace function public.tc_whoami(p_token text)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); p tc_private.players; v_room uuid;
begin
  update tc_private.players set last_seen_at = now() where id = v_me returning * into p;
  select m.room_id into v_room
  from tc_private.members m join tc_private.rooms r on r.id = m.room_id
  where m.player_id = v_me and m.left_at is null
    and r.status in ('lobby', 'countdown', 'question', 'reveal')
    and r.last_activity_at > now() - interval '15 minutes'
  order by r.last_activity_at desc limit 1;
  return jsonb_build_object('player_id', p.id, 'name', p.display_name, 'avatar', p.avatar, 'active_room_id', v_room);
end $$;

create or replace function public.tc_update_profile(p_token text, p_name text, p_avatar int)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); v_name text;
begin
  perform tc_private.rate('profile:' || v_me, 20, 600);
  v_name := tc_private.clean_name(p_name);
  if p_avatar is null or p_avatar < 0 or p_avatar > 11 then p_avatar := 0; end if;
  update tc_private.players set display_name = v_name, avatar = p_avatar where id = v_me;
  return jsonb_build_object('player_id', v_me, 'name', v_name, 'avatar', p_avatar);
end $$;

-- Permanently delete the guest identity and everything tied to it.
create or replace function public.tc_delete_account(p_token text)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); m record;
begin
  for m in select room_id from tc_private.members where player_id = v_me loop
    perform 1 from tc_private.rooms where id = m.room_id for update;
    perform tc_private.remove_member(m.room_id, v_me);
    perform tc_private.bump(m.room_id);
  end loop;
  update tc_private.match_results mr
  set standings = (select jsonb_agg(case when e ->> 'id' = v_me::text
                                         then e || jsonb_build_object('id', null, 'name', 'Deleted player')
                                         else e end)
                   from jsonb_array_elements(mr.standings) e)
  where mr.standings @> jsonb_build_array(jsonb_build_object('id', v_me));
  update tc_private.rooms set host_id = null where host_id = v_me;
  delete from tc_private.players where id = v_me;
  return jsonb_build_object('deleted', true);
end $$;

-- p_mode: 'solo' | 'ffa' | 'teams'. Solo matches start immediately.
create or replace function public.tc_create_room(p_token text, p_mode text, p_settings jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); p tc_private.players; v_room uuid;
begin
  perform tc_private.rate('create:' || v_me, 20, 600);
  if p_mode not in ('solo', 'ffa', 'teams') then
    raise exception 'invalid_mode' using errcode = 'P0001';
  end if;
  select * into p from tc_private.players where id = v_me;
  insert into tc_private.rooms (code, host_id, mode) values (tc_private.gen_code(), v_me, p_mode)
  returning id into v_room;
  perform tc_private.apply_settings(v_room, p_settings);
  insert into tc_private.members (room_id, player_id, nickname, avatar, is_ready)
  values (v_room, v_me, p.display_name, p.avatar, true);
  if p_mode = 'teams' then
    perform tc_private.fill_teams(v_room);
  end if;
  if p_mode = 'solo' then
    perform tc_private.start_match(v_room);
  end if;
  perform tc_private.bump(v_room);
  return tc_private.state_json(v_room, v_me);
end $$;

create or replace function public.tc_join_room(p_token text, p_code text)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare
  v_me uuid := tc_private.session(p_token);
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  r tc_private.rooms;
  m tc_private.members;
  p tc_private.players;
begin
  perform tc_private.rate('join:' || v_me, 20, 300);
  if length(v_code) <> 5 then
    raise exception 'room_not_found' using errcode = 'P0001';
  end if;
  select * into r from tc_private.rooms where code = v_code and status <> 'closed' for update;
  if not found or r.mode = 'solo' then
    raise exception 'room_not_found' using errcode = 'P0001';
  end if;
  select * into p from tc_private.players where id = v_me;
  select * into m from tc_private.members where room_id = r.id and player_id = v_me;
  if found then
    -- Rejoin / reconnect: restores the existing seat, score and answers.
    update tc_private.members
    set left_at = null, last_seen_at = clock_timestamp(),
        nickname = case when m.left_at is null then nickname else tc_private.unique_nick(r.id, nickname, v_me) end
    where room_id = r.id and player_id = v_me;
  else
    if r.status <> 'lobby' then
      raise exception 'match_in_progress' using errcode = 'P0001';
    end if;
    if (select count(*) from tc_private.members where room_id = r.id and left_at is null) >= 12 then
      raise exception 'room_full' using errcode = 'P0001';
    end if;
    insert into tc_private.members (room_id, player_id, nickname, avatar)
    values (r.id, v_me, tc_private.unique_nick(r.id, p.display_name, v_me), p.avatar);
    if r.mode = 'teams' then
      perform tc_private.fill_teams(r.id);
    end if;
  end if;
  if r.host_id is null then
    perform tc_private.reassign_host(r.id);
  end if;
  perform tc_private.bump(r.id);
  return tc_private.state_json(r.id, v_me);
end $$;

-- Rejoin by room id (used for resume after an app relaunch).
create or replace function public.tc_rejoin_room(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.status = 'closed'
     or not exists (select 1 from tc_private.members where room_id = p_room and player_id = v_me) then
    raise exception 'room_not_found' using errcode = 'P0001';
  end if;
  update tc_private.members set left_at = null, last_seen_at = clock_timestamp()
  where room_id = p_room and player_id = v_me;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

create or replace function public.tc_leave_room(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token);
begin
  perform 1 from tc_private.rooms where id = p_room for update;
  if exists (select 1 from tc_private.members where room_id = p_room and player_id = v_me) then
    perform tc_private.remove_member(p_room, v_me);
    perform tc_private.bump(p_room);
  end if;
  return jsonb_build_object('left', true);
end $$;

-- The polling / sync endpoint. Advances overdue phases, records presence and
-- returns the caller's filtered view of the room.
create or replace function public.tc_get_state(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare
  v_me uuid := tc_private.session(p_token);
  r tc_private.rooms;
  m tc_private.members;
  v_now timestamptz := clock_timestamp();
  v_host_seen timestamptz;
begin
  perform tc_private.rate('state:' || v_me, 60, 10);
  select * into m from tc_private.members where room_id = p_room and player_id = v_me;
  if not found then
    raise exception 'not_member' using errcode = 'P0001';
  end if;
  select * into r from tc_private.rooms where id = p_room;

  if (r.phase_ends_at is not null and r.phase_ends_at <= v_now)
     or m.last_seen_at < v_now - interval '3 seconds' then
    select * into r from tc_private.rooms where id = p_room for update;
    perform tc_private.advance(p_room);
    if m.last_seen_at < v_now - interval '3 seconds' and m.left_at is null then
      update tc_private.members set last_seen_at = v_now where room_id = p_room and player_id = v_me;
      if m.last_seen_at < v_now - interval '10 seconds' then
        perform tc_private.bump(p_room); -- came back online: let others see it
      end if;
    end if;
    -- A host who has vanished from a lobby hands over to someone present.
    if r.status in ('lobby', 'finished') and r.host_id is distinct from v_me and m.left_at is null then
      select last_seen_at into v_host_seen from tc_private.members
      where room_id = p_room and player_id = r.host_id and left_at is null;
      if v_host_seen is null or v_host_seen < v_now - interval '30 seconds' then
        perform tc_private.reassign_host(p_room);
        perform tc_private.bump(p_room);
      end if;
    end if;
  end if;
  return tc_private.state_json(p_room, v_me);
end $$;

create or replace function public.tc_set_ready(p_token text, p_room uuid, p_ready boolean)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  perform tc_private.rate('lobby:' || v_me, 40, 60);
  select * into r from tc_private.rooms where id = p_room for update;
  if r.status <> 'lobby' then raise exception 'not_in_lobby' using errcode = 'P0001'; end if;
  update tc_private.members set is_ready = coalesce(p_ready, false)
  where room_id = p_room and player_id = v_me and left_at is null;
  if not found then raise exception 'not_member' using errcode = 'P0001'; end if;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

create or replace function public.tc_update_settings(p_token text, p_room uuid, p_settings jsonb)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  perform tc_private.rate('lobby:' || v_me, 40, 60);
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.host_id is distinct from v_me then raise exception 'not_host' using errcode = 'P0001'; end if;
  if r.status <> 'lobby' then raise exception 'not_in_lobby' using errcode = 'P0001'; end if;
  perform tc_private.apply_settings(p_room, p_settings - 'mode');
  if p_settings ? 'mode' and p_settings ->> 'mode' in ('ffa', 'teams') then
    update tc_private.rooms set mode = p_settings ->> 'mode' where id = p_room;
    if p_settings ->> 'mode' = 'teams' then
      perform tc_private.fill_teams(p_room);
    else
      update tc_private.members set team = null where room_id = p_room;
    end if;
  end if;
  select * into r from tc_private.rooms where id = p_room;
  if r.mode = 'teams' then perform tc_private.fill_teams(p_room); end if;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

-- Move yourself (or, as host, anyone) to a team. Non-hosts cannot stack a team
-- beyond ceil(players / teams).
create or replace function public.tc_set_team(p_token text, p_room uuid, p_player uuid, p_team int)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare
  v_me uuid := tc_private.session(p_token);
  v_target uuid := coalesce(p_player, v_me);
  r tc_private.rooms;
  v_active int;
  v_size int;
begin
  perform tc_private.rate('lobby:' || v_me, 40, 60);
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.mode <> 'teams' then raise exception 'not_team_mode' using errcode = 'P0001'; end if;
  if r.status <> 'lobby' then raise exception 'not_in_lobby' using errcode = 'P0001'; end if;
  if v_target <> v_me and r.host_id is distinct from v_me then raise exception 'not_host' using errcode = 'P0001'; end if;
  if p_team is null or p_team < 0 or p_team >= r.team_count then raise exception 'invalid_team' using errcode = 'P0001'; end if;
  if not exists (select 1 from tc_private.members where room_id = p_room and player_id = v_target and left_at is null) then
    raise exception 'not_member' using errcode = 'P0001';
  end if;
  if v_target = v_me and r.host_id is distinct from v_me then
    select count(*) into v_active from tc_private.members where room_id = p_room and left_at is null;
    select count(*) into v_size from tc_private.members
    where room_id = p_room and left_at is null and team = p_team and player_id <> v_me;
    if v_size >= ceil(v_active::numeric / r.team_count) then
      raise exception 'team_full' using errcode = 'P0001';
    end if;
  end if;
  update tc_private.members set team = p_team where room_id = p_room and player_id = v_target;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

create or replace function public.tc_shuffle_teams(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  perform tc_private.rate('lobby:' || v_me, 40, 60);
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.host_id is distinct from v_me then raise exception 'not_host' using errcode = 'P0001'; end if;
  if r.mode <> 'teams' or r.status <> 'lobby' then raise exception 'not_in_lobby' using errcode = 'P0001'; end if;
  update tc_private.members m set team = s.t
  from (select player_id, ((row_number() over (order by random())) - 1) % r.team_count as t
        from tc_private.members where room_id = p_room and left_at is null) s
  where m.room_id = p_room and m.player_id = s.player_id;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

create or replace function public.tc_kick(p_token text, p_room uuid, p_player uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.host_id is distinct from v_me then raise exception 'not_host' using errcode = 'P0001'; end if;
  if r.status <> 'lobby' then raise exception 'not_in_lobby' using errcode = 'P0001'; end if;
  if p_player = v_me then raise exception 'invalid_target' using errcode = 'P0001'; end if;
  delete from tc_private.members where room_id = p_room and player_id = p_player;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

create or replace function public.tc_start_match(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  perform tc_private.rate('lobby:' || v_me, 40, 60);
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.host_id is distinct from v_me then raise exception 'not_host' using errcode = 'P0001'; end if;
  if r.status <> 'lobby' then raise exception 'not_in_lobby' using errcode = 'P0001'; end if;
  -- Players who have silently disappeared are dropped rather than blocking the start.
  delete from tc_private.members
  where room_id = p_room and player_id <> v_me and last_seen_at < clock_timestamp() - interval '30 seconds';
  if (select count(*) from tc_private.members where room_id = p_room and left_at is null) < 2 then
    raise exception 'need_more_players' using errcode = 'P0001';
  end if;
  if exists (select 1 from tc_private.members
             where room_id = p_room and left_at is null and player_id <> v_me and not is_ready) then
    raise exception 'players_not_ready' using errcode = 'P0001';
  end if;
  perform tc_private.start_match(p_room);
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

-- Submit an answer. p_choice is the position the player saw (0–3). The first
-- accepted answer is final; retries return the stored answer; anything that
-- arrives at or after the server deadline is rejected.
create or replace function public.tc_submit_answer(p_token text, p_room uuid, p_round int, p_choice int)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare
  v_me uuid := tc_private.session(p_token);
  r tc_private.rooms;
  m tc_private.members;
  rd tc_private.rounds;
  prev tc_private.answers;
  v_now timestamptz;
  v_perm smallint[];
  v_orig smallint;
  v_correct boolean;
  s record;
  v_remaining int;
begin
  if p_choice is null or p_choice < 0 or p_choice > 3 then
    raise exception 'invalid_choice' using errcode = 'P0001';
  end if;
  perform tc_private.rate('submit:' || v_me, 20, 10);

  perform 1 from tc_private.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0001'; end if;
  -- Timestamp taken immediately after acquiring the lock: this is the official
  -- receive time used both for the deadline check and the speed bonus.
  v_now := clock_timestamp();
  select * into m from tc_private.members where room_id = p_room and player_id = v_me;
  if not found or m.left_at is not null then raise exception 'not_member' using errcode = 'P0001'; end if;

  select rd2.* into rd from tc_private.rounds rd2 join tc_private.rooms r2 on r2.id = rd2.room_id
  where rd2.room_id = p_room and rd2.match_no = r2.match_no and rd2.round_no = p_round;
  if not found or rd.opens_at is null then
    raise exception 'invalid_round' using errcode = 'P0001';
  end if;

  select * into prev from tc_private.answers where round_id = rd.id and player_id = v_me;
  if found then
    return jsonb_build_object('status', 'already_answered', 'choice', prev.shown_choice);
  end if;

  if v_now >= rd.closes_at or rd.closed_at is not null or v_now < rd.opens_at then
    perform tc_private.advance(p_room);
    return jsonb_build_object('status', 'too_late');
  end if;

  v_perm := tc_private.perm(rd.seed, v_me);
  v_orig := v_perm[p_choice + 1];
  select (q.correct_index = v_orig) into v_correct from tc_private.questions q where q.id = rd.question_id;
  v_remaining := greatest(0, (tc_private.ms(rd.closes_at) - tc_private.ms(v_now))::int);
  select * into s from tc_private.score(v_correct, v_remaining, m.streak, rd.multiplier);

  insert into tc_private.answers (round_id, player_id, room_id, choice, shown_choice, received_at, response_ms,
                                  is_correct, base_points, speed_bonus, streak_bonus, points)
  values (rd.id, v_me, p_room, v_orig, p_choice, v_now, 10000 - v_remaining,
          v_correct, s.base, s.speed, s.streak_bonus, s.total)
  on conflict (round_id, player_id) do nothing;

  -- Everyone still in the match has answered: close the round early.
  if not exists (select 1 from tc_private.members mm
                 where mm.room_id = p_room and mm.left_at is null
                   and not exists (select 1 from tc_private.answers aa
                                   where aa.round_id = rd.id and aa.player_id = mm.player_id)) then
    perform tc_private.close_round(p_room, v_now);
  end if;
  perform tc_private.bump(p_room);
  -- Correctness is intentionally NOT returned here; it is revealed with the round.
  return jsonb_build_object('status', 'accepted', 'choice', p_choice);
end $$;

-- Solo only: skip the rest of the reveal and continue to the next question.
create or replace function public.tc_next(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.mode <> 'solo' or r.host_id is distinct from v_me then
    raise exception 'not_allowed' using errcode = 'P0001';
  end if;
  if r.status = 'reveal' then
    update tc_private.rooms set phase_ends_at = clock_timestamp() - interval '1 millisecond' where id = p_room;
    perform tc_private.advance(p_room);
  end if;
  return tc_private.state_json(p_room, v_me);
end $$;

-- Host: return a finished room to the lobby for another match with the same group.
create or replace function public.tc_rematch(p_token text, p_room uuid)
returns jsonb language plpgsql security definer
set search_path = tc_private, pg_temp as $$
declare v_me uuid := tc_private.session(p_token); r tc_private.rooms;
begin
  select * into r from tc_private.rooms where id = p_room for update;
  if not found or r.host_id is distinct from v_me then raise exception 'not_host' using errcode = 'P0001'; end if;
  if r.status <> 'finished' then raise exception 'not_finished' using errcode = 'P0001'; end if;
  delete from tc_private.members where room_id = p_room and left_at is not null;
  update tc_private.members set is_ready = (player_id = v_me), score = 0, correct = 0, answered = 0,
    streak = 0, best_streak = 0, correct_ms = 0, fastest_ms = null, last_points = 0, last_correct = null
  where room_id = p_room;
  update tc_private.rooms set status = 'lobby', current_round = 0, total_rounds = 0, phase_ends_at = null
  where id = p_room;
  delete from tc_private.rounds where room_id = p_room;
  perform tc_private.bump(p_room);
  return tc_private.state_json(p_room, v_me);
end $$;

-- Category counts for the setup screens (no question content).
create or replace function public.tc_catalog()
returns jsonb language sql security definer stable
set search_path = tc_private, pg_temp as $$
  select jsonb_build_object(
    'total', (select count(*) from tc_private.questions where review_status = 'approved'),
    'categories', coalesce((select jsonb_object_agg(category, n) from (
        select category, count(*) n from tc_private.questions where review_status = 'approved' group by category) c), '{}'::jsonb))
$$;

-- Lock down execution: only the API functions are callable by API roles.
revoke execute on all functions in schema tc_private from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'tc_register(text,int)', 'tc_whoami(text)', 'tc_update_profile(text,text,int)', 'tc_delete_account(text)',
    'tc_create_room(text,text,jsonb)', 'tc_join_room(text,text)', 'tc_rejoin_room(text,uuid)',
    'tc_leave_room(text,uuid)', 'tc_get_state(text,uuid)', 'tc_set_ready(text,uuid,boolean)',
    'tc_update_settings(text,uuid,jsonb)', 'tc_set_team(text,uuid,uuid,int)', 'tc_shuffle_teams(text,uuid)',
    'tc_kick(text,uuid,uuid)', 'tc_start_match(text,uuid)', 'tc_submit_answer(text,uuid,int,int)',
    'tc_next(text,uuid)', 'tc_rematch(text,uuid)', 'tc_catalog()'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
