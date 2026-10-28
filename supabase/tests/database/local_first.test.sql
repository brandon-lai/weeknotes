-- Local-first rules: anonymous sessions stay out of everything social, and weeks written
-- before signing in can be backed up with their original week.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

insert into auth.users (id, aud, role, email, is_anonymous, raw_app_meta_data, raw_user_meta_data, created_at, updated_at) values
  ('00000000-0000-0000-0000-0000000000f1', 'authenticated', 'authenticated', null, true, '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-0000000000f2', 'authenticated', 'authenticated', 'writer@test.local', false, '{}', '{}', now(), now());

create function pg_temp.login(who uuid, anonymous boolean) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', who, 'role', 'authenticated', 'is_anonymous', anonymous)::text, true)
$$;

-- An anonymous session can't become a social account
select pg_temp.login('00000000-0000-0000-0000-0000000000f1', true);
select throws_ok($$insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Ghost', 'UTC')$$, '42501', null, 'anonymous users cannot create a profile');
select throws_ok($$select public.publish_update(gen_random_uuid(), null, 'hi', null, '{}', 0, '{}')$$, 'P0001', 'Set up your profile before posting', 'nor post');
select throws_ok($$insert into public.circles (owner_id, name) values (auth.uid(), 'x')$$, '23503', null, 'nor make circles');
select throws_ok($$select public.send_friend_request('00000000-0000-0000-0000-0000000000f2')$$, null, null, 'nor send friend requests');
select throws_ok($$insert into storage.objects (bucket_id, name, owner) values ('photos', '00000000-0000-0000-0000-0000000000f1/00000000-0000-0000-0000-000000000099/x.jpg', auth.uid())$$, '42501', null, 'nor upload files');

-- A real account backs up weeks written before signing in
select pg_temp.login('00000000-0000-0000-0000-0000000000f2', false);
insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Writer', 'America/New_York');
select lives_ok($$select public.publish_update('30000000-0000-0000-0000-000000000001', null, 'Three weeks ago', null, array['typed'], 1000, '{}',
                   null, '[]', (public.my_week_start() - 21), now() - interval '20 days')$$, 'backfilling a past week works');
select is((select week_start from public.updates where id = '30000000-0000-0000-0000-000000000001'), public.my_week_start() - 21, 'it keeps its original week');
select ok((select posted_at < now() - interval '19 days' from public.updates where id = '30000000-0000-0000-0000-000000000001'), 'and its original time');
select lives_ok($$select public.publish_update('30000000-0000-0000-0000-000000000002', null, 'From the future', null, array['typed'], 1000, '{}',
                   null, '[]', (public.my_week_start() + 28), now() + interval '30 days')$$, 'a future week is accepted but clamped');
select is((select week_start from public.updates where id = '30000000-0000-0000-0000-000000000002'), public.my_week_start(), 'to the current week');
select ok((select posted_at <= now() from public.updates where id = '30000000-0000-0000-0000-000000000002'), 'and the current time');
-- A non-Monday "week" is corrected to the current week, which the clamped entry above already
-- holds: one update per person per week still applies
select throws_ok($$select public.publish_update('30000000-0000-0000-0000-000000000003', null, 'Not a Monday', null, array['typed'], 1000, '{}',
                   null, '[]', (public.my_week_start() - 12), null)$$, '23505', null, 'a non-Monday week is corrected, and one update per week still holds');
select is((select count(*)::int from public.update_audiences), 0, 'backed-up weeks are shared with nobody');

-- The server reminder job is gone; reminders are local notifications now
select set_config('role', 'postgres', true);
select is((select count(*)::int from cron.job where jobname = 'weeknotes-reminders'), 0, 'no server reminder job');

select * from finish();
rollback;
