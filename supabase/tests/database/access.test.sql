-- Row level security and RPC behavior, run with `supabase test db`.
-- M0: RLS tests pass for update visibility. M5: an update posted to one circle is visible to
-- its members and not to a friend outside it.
begin;
create extension if not exists pgtap with schema extensions;
select * from no_plan();

-- People: Ana posts. Ben is her friend in College. Cal is her friend outside it.
-- Eve is a stranger who later joins from a share link.
insert into auth.users (id, aud, role, email, phone, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-00000000000a', 'authenticated', 'authenticated', 'ana@test.local', '15555550101', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-00000000000b', 'authenticated', 'authenticated', 'ben@test.local', '15555550102', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-00000000000c', 'authenticated', 'authenticated', 'cal@test.local', '15555550103', null, '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-00000000000e', 'authenticated', 'authenticated', 'eve@test.local', null, null, '{}', '{}', now(), now());

create function pg_temp.login(who uuid) returns void language sql as $$
  select set_config('role', 'authenticated', true),
         set_config('request.jwt.claims', json_build_object('sub', who, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.logout() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true)
$$;

-- ---- Profiles ------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Ana', 'America/Toronto')$$, 'Ana creates her profile');
select throws_ok($$insert into public.profiles (id, display_name, timezone) values ('00000000-0000-0000-0000-00000000000b', 'Fake Ben', 'UTC')$$, '42501', null, 'cannot create someone else''s profile');
select throws_ok($$update public.profiles set phone_hash = 'x' where id = auth.uid()$$, '42501', null, 'phone_hash is not writable');
select throws_ok($$select phone_hash from public.profiles$$, '42501', null, 'phone_hash is not readable');
select throws_ok($$insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Ana', 'Mars/Olympus')$$, '23514', null, 'time zone must be real');
select is((select has_verified_phone from public.my_profile()), true, 'verified phone produces a hash');

select pg_temp.login('00000000-0000-0000-0000-00000000000b');
insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Ben', 'America/New_York');
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Cal', 'Europe/London');
select is((select has_verified_phone from public.my_profile()), false, 'unverified phone is not matchable');
select pg_temp.login('00000000-0000-0000-0000-00000000000e');
insert into public.profiles (id, display_name, timezone) values (auth.uid(), 'Eve', 'UTC');

-- ---- Contact matching ----------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select results_eq(
  $$select display_name from public.match_contacts(array[
      encode(extensions.digest('+15555550102', 'sha256'), 'hex'),
      encode(extensions.digest('+15555550103', 'sha256'), 'hex'),
      encode(extensions.digest('+15555550199', 'sha256'), 'hex')])$$,
  $$values ('Ben')$$,
  'contacts match verified phones only'
);

-- ---- Friends -------------------------------------------------------------
select is(public.send_friend_request('00000000-0000-0000-0000-00000000000b'), 'pending', 'Ana asks Ben');
select is(public.send_friend_request('00000000-0000-0000-0000-00000000000c'), 'pending', 'Ana asks Cal');
select throws_ok($$insert into public.friendships values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000e', 'accepted', '00000000-0000-0000-0000-00000000000a')$$, '42501', null, 'friendships are not directly writable');
select is((select count(*)::int from public.profiles where display_name = 'Eve'), 0, 'strangers'' profiles are hidden');

select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is(public.respond_friend_request('00000000-0000-0000-0000-00000000000a', true), 'accepted', 'Ben accepts');
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select is(public.send_friend_request('00000000-0000-0000-0000-00000000000a'), 'accepted', 'asking back accepts Cal''s pending request');

-- ---- Circles -------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
insert into public.circles (id, owner_id, name) values ('10000000-0000-0000-0000-000000000001', auth.uid(), 'College');
select lives_ok($$insert into public.circle_members values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000b')$$, 'friends can be added to a circle');
select throws_ok($$insert into public.circle_members values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000e')$$, '42501', null, 'strangers cannot be added to a circle');

select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.circles), 0, 'members don''t see the author''s circles');
select throws_ok($$insert into public.circle_members values ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000c')$$, '42501', null, 'only the owner manages a circle');

-- ---- Posting -------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select lives_ok($$
  select public.publish_update(
    '20000000-0000-0000-0000-000000000001', 'Best part of your week?', 'Ran 3.1 miles at 6:30 am.', 'ran three point one miles',
    array['dictated', 'memo'], 240000, array['10000000-0000-0000-0000-000000000001']::uuid[],
    '{"storage_path": "00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/memo.m4a", "duration_ms": 61000, "waveform": [0.1, 0.5, 1], "transcript_clean": "Hi.", "engine_id": "apple-speech"}',
    '[{"storage_path": "00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/0.jpg", "position": 0, "width": 1200, "height": 900}]'
  )$$, 'Ana posts to College with a memo and a photo');
select is((select week_start from public.updates where id = '20000000-0000-0000-0000-000000000001'), public.week_start_for(now(), 'America/Toronto', 12), 'the server sets the week in the author''s time zone');
select throws_ok($$insert into public.updates (id, body_text) values (gen_random_uuid(), 'second post this week')$$, '23505', null, 'one update per person per week');
select throws_ok($$select public.publish_update(gen_random_uuid(), null, '  ', null, '{}', 0, '{}', null, '[]')$$, 'P0001', null, 'an update needs text or a memo');

-- Ben (member of College) reads it, Cal (friend outside it) and Eve (stranger) don't
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.updates where id = '20000000-0000-0000-0000-000000000001'), 1, 'circle member reads the update');
select is((select count(*)::int from public.voice_memos), 1, 'circle member reads the memo row');
select is((select count(*)::int from public.update_photos), 1, 'circle member reads the photos');
select is((select count(*)::int from public.feed()), 1, 'it is in the member''s feed');
select is((select count(*)::int from public.update_audiences), 0, 'readers don''t see the audience list');
select is((select body_raw_transcript from public.updates where id = '20000000-0000-0000-0000-000000000001'), 'ran three point one miles', 'the raw transcript is kept and viewable');
update public.updates set body_text = 'hacked' where id = '20000000-0000-0000-0000-000000000001';
select is((select body_text from public.updates where id = '20000000-0000-0000-0000-000000000001'), 'Ran 3.1 miles at 6:30 am.', 'readers cannot edit');

select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.updates), 0, 'a friend outside the circle cannot read it');
select is((select count(*)::int from public.voice_memos), 0, 'nor its memo');
select is((select count(*)::int from public.update_photos), 0, 'nor its photos');
select is((select count(*)::int from public.feed()), 0, 'nor see it in the feed');

select pg_temp.login('00000000-0000-0000-0000-00000000000e');
select is((select count(*)::int from public.updates), 0, 'a stranger cannot read it');

select pg_temp.logout();
set local role anon;
select throws_ok($$select count(*) from public.updates$$, '42501', null, 'anonymous users cannot read updates');
select pg_temp.logout();

-- ---- Reactions and reads -------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select lives_ok($$insert into public.reactions (update_id, user_id, emoji) values ('20000000-0000-0000-0000-000000000001', auth.uid(), '❤️')$$, 'member reacts');
select lives_ok($$select public.mark_read('20000000-0000-0000-0000-000000000001', 30000)$$, 'member marks it read');
select lives_ok($$select public.mark_read('20000000-0000-0000-0000-000000000001', 1000)$$, 'listening progress never goes backwards');
select is((select listened_ms from public.reads), 30000, 'listened_ms keeps the furthest point');
select is((select read_at is not null from public.feed()), true, 'feed shows it read');

select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select throws_ok($$insert into public.reactions (update_id, user_id, emoji) values ('20000000-0000-0000-0000-000000000001', auth.uid(), '🔥')$$, '42501', null, 'non-members cannot react');

select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select is((select emoji from public.reactions), '❤️', 'the author sees reactions');
select is((select listened_ms from public.reads), 30000, 'the author sees listening progress');

-- ---- Replies -------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select isnt(public.open_thread('00000000-0000-0000-0000-00000000000a'), null, 'Ben opens a thread with Ana');
select lives_ok($$insert into public.messages (thread_id, sender_id, update_id, body)
                  values ((select id from public.threads), auth.uid(), '20000000-0000-0000-0000-000000000001', 'Nice run!')$$,
                'Ben replies privately');
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select is((select unread from public.inbox()), 1, 'Ana has one unread reply');
select lives_ok($$select public.mark_thread_read((select thread_id from public.inbox()))$$, 'Ana reads it');
select is((select unread from public.inbox()), 0, 'and it is no longer unread');
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.messages), 0, 'others cannot read the thread');
select pg_temp.login('00000000-0000-0000-0000-00000000000e');
select throws_ok($$select public.open_thread('00000000-0000-0000-0000-00000000000a')$$, '42501', null, 'only friends can message');

-- ---- require_post_to_read ------------------------------------------------
select pg_temp.logout();
update public.app_config set require_post_to_read = true;
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.updates), 0, 'with require_post_to_read, Ben must post first');
select lives_ok($$select public.publish_update(gen_random_uuid(), null, 'Quiet week.', null, array['typed'], 60000, '{}', null, '[]')$$, 'Ben posts to his archive only');
select is((select count(*)::int from public.updates where author_id = '00000000-0000-0000-0000-00000000000a'), 1, 'then he can read Ana''s');
select pg_temp.logout();
update public.app_config set require_post_to_read = false;

-- An archive-only update is visible to nobody else
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.updates where author_id = '00000000-0000-0000-0000-00000000000b'), 0, 'an update with no circles stays private');

-- ---- Share links and invites ---------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
create temp table link on commit drop as
  select * from public.create_share_link('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
grant select on link to authenticated;
select is((select token from public.create_share_link('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001')), (select token from link), 'an existing link is reused');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.create_share_link('20000000-0000-0000-0000-000000000001')$$, '42501', null, 'only the author makes share links');

select pg_temp.login('00000000-0000-0000-0000-00000000000e');
select is((select inviter_name from public.accept_invite((select token from link))), 'Ana', 'Eve joins from Ana''s link');
select is((select count(*)::int from public.updates where id = '20000000-0000-0000-0000-000000000001'), 1, 'and is now in College, so she can read it');
select pg_temp.logout();
update public.share_links set expires_at = now() - interval '1 minute';
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select throws_ok($$select public.accept_invite((select token from link))$$, 'P0002', 'This link has expired', 'expired links refuse');

-- ---- Unfriending ---------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.remove_friend('00000000-0000-0000-0000-00000000000b')$$, 'Ana removes Ben');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.updates where author_id = '00000000-0000-0000-0000-00000000000a'), 0, 'Ben can no longer read Ana''s update');

-- ---- Deleting an update deletes its files ---------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a');
delete from public.updates where id = '20000000-0000-0000-0000-000000000001';
select pg_temp.logout();
select results_eq(
  $$select bucket, path from private.storage_garbage order by bucket$$,
  $$values ('memos', '00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/memo.m4a'),
           ('photos', '00000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-000000000001/0.jpg')$$,
  'the memo and photo files are queued for deletion'
);

select * from finish();
rollback;
