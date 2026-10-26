-- Week boundaries (shared vectors with WeekTests in the app) and reminder scheduling.
-- M7: a user with a reminder at a given local time gets it within 15 minutes, and not if they
-- already posted this week.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- Same vectors as WeeknotesCoreTests/SupportTests.swift, WeekTests.weekStart
select is(public.week_start_for('2026-10-26T15:59:00Z', 'America/Toronto'), '2026-10-19'::date, 'Mon 11:59 local counts toward last week');
select is(public.week_start_for('2026-10-26T16:00:00Z', 'America/Toronto'), '2026-10-26'::date, 'Mon 12:00 local starts the new week');
select is(public.week_start_for('2026-10-26T03:59:00Z', 'America/Toronto'), '2026-10-19'::date, 'Sun 23:59 local');
select is(public.week_start_for('2026-10-21T12:00:00Z', 'America/Toronto'), '2026-10-19'::date, 'Wednesday');
select is(public.week_start_for('2026-10-26T02:00:00Z', 'Asia/Tokyo'), '2026-10-19'::date, 'Mon 11:00 Tokyo');
select is(public.week_start_for('2026-10-26T03:00:00Z', 'Asia/Tokyo'), '2026-10-26'::date, 'Mon 12:00 Tokyo');
select is(public.week_start_for('2026-11-02T15:30:00Z', 'America/Toronto'), '2026-10-26'::date, 'Mon 10:30 after DST ends');
select is(public.week_start_for('2027-01-03T23:00:00Z', 'UTC'), '2026-12-28'::date, 'across a year');
select is(public.week_start_for('2026-10-26T13:00:00Z', 'America/Toronto', 0), '2026-10-26'::date, 'the cutoff is configurable');

insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-0000000000a1', 'authenticated', 'authenticated', 'rem1@test.local', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-0000000000a2', 'authenticated', 'authenticated', 'rem2@test.local', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-0000000000a3', 'authenticated', 'authenticated', 'rem3@test.local', '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-0000000000a4', 'authenticated', 'authenticated', 'rem4@test.local', '{}', '{}', now(), now());

-- Toronto, default Sunday 18:00 · Tokyo, Friday 21:30 · a poster · reminders off
insert into public.profiles (id, display_name, timezone, reminder_weekday, reminder_time, reminders_enabled) values
  ('00000000-0000-0000-0000-0000000000a1', 'Toronto', 'America/Toronto', 0, '18:00', true),
  ('00000000-0000-0000-0000-0000000000a2', 'Tokyo', 'Asia/Tokyo', 5, '21:30', true),
  ('00000000-0000-0000-0000-0000000000a3', 'Poster', 'America/Toronto', 0, '18:00', true),
  ('00000000-0000-0000-0000-0000000000a4', 'Off', 'America/Toronto', 0, '18:00', false);
insert into public.push_tokens (token, user_id) values
  (repeat('a', 64), '00000000-0000-0000-0000-0000000000a1'),
  (repeat('b', 64), '00000000-0000-0000-0000-0000000000a2'),
  (repeat('c', 64), '00000000-0000-0000-0000-0000000000a3'),
  (repeat('d', 64), '00000000-0000-0000-0000-0000000000a4');

-- The poster already posted for the week of Oct 19 (direct insert as the service would see it)
alter table public.updates disable trigger updates_stamp;
insert into public.updates (author_id, week_start, body_text) values ('00000000-0000-0000-0000-0000000000a3', '2026-10-19', 'done');
alter table public.updates enable trigger updates_stamp;

-- Sunday Oct 25 17:59 Toronto = 21:59Z: nobody yet
select is((select count(*)::int from public.due_reminders('2026-10-25T21:59:00Z')), 0, 'nothing before the reminder time');
-- 18:00 Toronto = 22:00Z: Toronto is due; the poster isn't; reminders-off isn't
select results_eq($$select user_id from public.due_reminders('2026-10-25T22:00:00Z')$$,
                  $$values ('00000000-0000-0000-0000-0000000000a1'::uuid)$$, 'due at the local reminder time, skipping anyone who posted');
select is((select week_start from public.due_reminders('2026-10-25T22:14:00Z')), '2026-10-19'::date, 'the reminder is for the week that is ending');
-- After the reminder is logged it is not sent again
insert into public.reminder_log (user_id, week_start) values ('00000000-0000-0000-0000-0000000000a1', '2026-10-19');
select is((select count(*)::int from public.due_reminders('2026-10-25T22:15:00Z')), 0, 'sent once per week');
-- Tokyo: Friday Oct 23 21:30 JST = 12:30Z
select results_eq($$select user_id from public.due_reminders('2026-10-23T12:30:00Z')$$,
                  $$values ('00000000-0000-0000-0000-0000000000a2'::uuid)$$, 'time zones are respected');
select is((select count(*)::int from public.due_reminders('2026-10-23T13:31:00Z')), 0, 'an hour late is too late');

-- Only the service role can list reminders
set local role authenticated;
select throws_ok($$select * from public.due_reminders()$$, '42501', null, 'clients cannot list reminders');

select * from finish();
rollback;
