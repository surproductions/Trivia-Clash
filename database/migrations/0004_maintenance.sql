-- Trivia Clash: housekeeping, run every 5 minutes by pg_cron.
--   * rooms where no active member has been seen for 15 minutes are closed
--   * any room older than 12 hours is closed
--   * closed rooms are deleted after 2 days (cascades rounds/answers/members)
--   * rate-limit buckets older than a day and question history older than
--     60 days are purged; guests unseen for 180 days are deleted
create or replace function tc_private.maintenance() returns void
language plpgsql
set search_path = tc_private, pg_temp as $$
begin
  update tc_private.rooms r set status = 'closed', phase_ends_at = null
  where r.status <> 'closed'
    and (r.created_at < now() - interval '12 hours'
         or not exists (select 1 from tc_private.members m
                        where m.room_id = r.id and m.left_at is null
                          and m.last_seen_at > now() - interval '15 minutes'));
  delete from tc_private.rooms where status = 'closed' and last_activity_at < now() - interval '2 days';
  delete from tc_private.rate_hits where window_start < now() - interval '1 day';
  delete from tc_private.seen where seen_at < now() - interval '60 days';
  delete from tc_private.players p where p.last_seen_at < now() - interval '180 days'
    and not exists (select 1 from tc_private.members m where m.player_id = p.id);
  delete from tc_private.match_results where finished_at < now() - interval '90 days';
end $$;

revoke execute on function tc_private.maintenance() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'tc-maintenance';
select cron.schedule('tc-maintenance', '*/5 * * * *', $$select tc_private.maintenance()$$);
