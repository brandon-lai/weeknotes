-- Scheduled jobs (PRD §12, "Reminders"): pg_cron calls the reminders Edge Function every
-- 15 minutes and the storage sweep hourly, through pg_net.
--
-- The jobs read their target from private.secrets, so nothing environment-specific is in
-- this file. Until the owner sets them (README, "Launch checklist"), the jobs do nothing:
--   insert into private.secrets values
--     ('functions_url', 'https://<ref>.supabase.co/functions/v1'),
--     ('cron_secret', '<same value as the CRON_SECRET function secret>')
--   on conflict (name) do update set value = excluded.value;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function private.call_function(fn text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  base text := (select value from private.secrets where name = 'functions_url');
  secret text := (select value from private.secrets where name = 'cron_secret');
begin
  if base is null or secret is null then
    return null;
  end if;
  return net.http_post(
    url := base || '/' || fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
end;
$$;

select cron.unschedule(jobid) from cron.job where jobname in ('weeknotes-reminders', 'weeknotes-sweep');
select cron.schedule('weeknotes-reminders', '*/15 * * * *', $$select private.call_function('reminders')$$);
select cron.schedule('weeknotes-sweep', '7 * * * *', $$select private.call_function('sweep')$$);
