-- RPCs the app calls. Grants are explicit: anything not granted here can't be called.

-- ============================================================
-- Profile
-- ============================================================

create or replace function public.my_profile()
returns table (
  id uuid, display_name text, timezone text, reminder_weekday int, reminder_time time,
  reminders_enabled boolean, has_verified_phone boolean, week_start date, created_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select p.id, p.display_name, p.timezone, p.reminder_weekday, p.reminder_time, p.reminders_enabled,
         p.phone_hash is not null, public.my_week_start(), p.created_at
  from public.profiles p where p.id = auth.uid()
$$;
grant execute on function public.my_profile() to authenticated;
grant execute on function public.my_week_start() to authenticated;
grant execute on function public.week_start_for(timestamptz, text, int) to authenticated, anon;
grant execute on function public.can_read_update(uuid) to authenticated;

-- ============================================================
-- Friends
-- ============================================================

create or replace function public.my_friends()
returns table (id uuid, display_name text, status text, requested_by_me boolean, since timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, p.display_name, f.status, f.requested_by = auth.uid(), f.created_at
  from public.friendships f
  join public.profiles p on p.id = case when f.user_a = auth.uid() then f.user_b else f.user_a end
  where auth.uid() in (f.user_a, f.user_b)
  order by f.status, p.display_name
$$;
grant execute on function public.my_friends() to authenticated;

create or replace function public.send_friend_request(target uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  existing public.friendships;
begin
  if me is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if target = me then raise exception 'That''s you' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.profiles where id = target) then
    raise exception 'No such person' using errcode = 'P0002';
  end if;
  select * into existing from public.friendships where user_a = least(me, target) and user_b = greatest(me, target);
  if found then
    -- They already asked us: asking back accepts
    if existing.status = 'pending' and existing.requested_by = target then
      update public.friendships set status = 'accepted' where user_a = existing.user_a and user_b = existing.user_b;
      return 'accepted';
    end if;
    return existing.status;
  end if;
  insert into public.friendships (user_a, user_b, status, requested_by)
  values (least(me, target), greatest(me, target), 'pending', me);
  return 'pending';
end;
$$;
grant execute on function public.send_friend_request(uuid) to authenticated;

create or replace function public.respond_friend_request(requester uuid, accept boolean) returns text
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  if accept then
    update public.friendships set status = 'accepted'
    where user_a = least(me, requester) and user_b = greatest(me, requester)
      and status = 'pending' and requested_by = requester;
    if not found then raise exception 'No request from them' using errcode = 'P0002'; end if;
    return 'accepted';
  end if;
  delete from public.friendships
  where user_a = least(me, requester) and user_b = greatest(me, requester) and status = 'pending' and requested_by = requester;
  return 'declined';
end;
$$;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

-- Removing a friend (or cancelling a request) also takes each of you out of the other's circles.
create or replace function public.remove_friend(other uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
begin
  delete from public.friendships where user_a = least(me, other) and user_b = greatest(me, other);
  delete from public.circle_members cm using public.circles c
  where cm.circle_id = c.id
    and ((c.owner_id = me and cm.user_id = other) or (c.owner_id = other and cm.user_id = me));
end;
$$;
grant execute on function public.remove_friend(uuid) to authenticated;

-- Contact matching: the app sends sha256 hashes of E.164 numbers; we pepper and compare.
-- At most 3,000 hashes per call and 30 calls a day per user, so the endpoint can't be used to
-- enumerate the phone number space.
create or replace function public.match_contacts(hashes text[])
returns table (id uuid, display_name text, status text, requested_by_me boolean)
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  used int;
begin
  if me is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if cardinality(hashes) > 3000 then raise exception 'Too many contacts at once' using errcode = '54000'; end if;
  insert into private.match_log (user_id, day, calls) values (me, current_date, 1)
  on conflict (user_id, day) do update set calls = private.match_log.calls + 1
  returning calls into used;
  if used > 30 then raise exception 'Contact matching is limited to 30 times a day' using errcode = '54000'; end if;

  return query
  select p.id, p.display_name, f.status, f.requested_by = me
  from public.profiles p
  left join public.friendships f on f.user_a = least(p.id, me) and f.user_b = greatest(p.id, me)
  where p.phone_hash in (select private.peppered(h) from unnest(hashes) h where h ~ '^[0-9a-fA-F]{64}$')
    and p.id <> me
  order by p.display_name;
end;
$$;
grant execute on function public.match_contacts(text[]) to authenticated;

-- ============================================================
-- Posting
-- ============================================================

-- Creates or edits this week's update with its audience and media in one transaction.
-- The app picks the id up front so it can upload files to `{user}/{update}/...` first.
-- An empty `circles` array is allowed: the update goes to the archive only.
create or replace function public.publish_update(
  p_id uuid,
  p_prompt text,
  p_body text,
  p_raw_transcript text,
  p_composed_with text[],
  p_compose_ms int,
  p_circles uuid[],
  p_memo jsonb default null,     -- {storage_path, duration_ms, waveform, transcript_raw, transcript_clean, engine_id}
  p_photos jsonb default '[]'    -- [{storage_path, position, width, height}]
) returns public.updates
language plpgsql security invoker set search_path = '' as $$
declare
  result public.updates;
begin
  if coalesce(btrim(p_body), '') = '' and p_memo is null then
    raise exception 'Write something or record a memo' using errcode = 'P0001';
  end if;
  if jsonb_array_length(coalesce(p_photos, '[]')) > 4 then
    raise exception 'Up to 4 photos' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.updates where id = p_id) then
    update public.updates
    set prompt = p_prompt, body_text = nullif(btrim(p_body), ''), body_raw_transcript = p_raw_transcript,
        composed_with = p_composed_with, compose_ms = coalesce(compose_ms, p_compose_ms)
    where id = p_id
    returning * into result;
    if not found then raise exception 'Not your update' using errcode = '42501'; end if;
  else
    insert into public.updates (id, prompt, body_text, body_raw_transcript, composed_with, compose_ms)
    values (p_id, p_prompt, nullif(btrim(p_body), ''), p_raw_transcript, p_composed_with, p_compose_ms)
    returning * into result;
  end if;

  delete from public.update_audiences where update_id = p_id and circle_id <> all (coalesce(p_circles, '{}'));
  insert into public.update_audiences (update_id, circle_id)
  select p_id, c from unnest(coalesce(p_circles, '{}')) c
  on conflict do nothing;

  if p_memo is null then
    delete from public.voice_memos where update_id = p_id;
  else
    insert into public.voice_memos (update_id, storage_path, duration_ms, waveform, transcript_raw, transcript_clean, engine_id)
    values (
      p_id, p_memo->>'storage_path', (p_memo->>'duration_ms')::int, p_memo->'waveform',
      p_memo->>'transcript_raw', p_memo->>'transcript_clean', p_memo->>'engine_id'
    )
    on conflict (update_id) do update set
      storage_path = excluded.storage_path, duration_ms = excluded.duration_ms, waveform = excluded.waveform,
      transcript_raw = excluded.transcript_raw, transcript_clean = excluded.transcript_clean, engine_id = excluded.engine_id;
  end if;

  delete from public.update_photos
  where update_id = p_id
    and storage_path not in (select x->>'storage_path' from jsonb_array_elements(coalesce(p_photos, '[]')) x);
  insert into public.update_photos (update_id, storage_path, position, width, height)
  select p_id, x->>'storage_path', (x->>'position')::int, (x->>'width')::int, (x->>'height')::int
  from jsonb_array_elements(coalesce(p_photos, '[]')) x
  on conflict (update_id, position) do update set
    storage_path = excluded.storage_path, width = excluded.width, height = excluded.height;

  return result;
end;
$$;
grant execute on function public.publish_update(uuid, text, text, text, text[], int, uuid[], jsonb, jsonb) to authenticated;

-- ============================================================
-- Reading
-- ============================================================

-- This week's feed: one card per friend who posted, unread first. Friends whose update landed
-- in the previous week (a Sunday-night post read on Monday afternoon, or across time zones)
-- still show while unread for four days. RLS decides what's visible.
create or replace function public.feed()
returns table (
  update_id uuid, author_id uuid, author_name text, week_start date, is_current_week boolean,
  prompt text, body_text text, posted_at timestamptz, edited_at timestamptz,
  memo jsonb, photos jsonb, read_at timestamptz, listened_ms int, my_reaction text
)
language sql stable security invoker set search_path = '' as $$
  with week as (select public.my_week_start() as current_week)
  select u.id, u.author_id, p.display_name, u.week_start, u.week_start = w.current_week,
         u.prompt, u.body_text, u.posted_at, u.edited_at,
         (select jsonb_build_object('id', m.id, 'storage_path', m.storage_path, 'duration_ms', m.duration_ms,
                                    'waveform', m.waveform, 'transcript_clean', m.transcript_clean, 'transcript_raw', m.transcript_raw)
          from public.voice_memos m where m.update_id = u.id),
         coalesce((select jsonb_agg(jsonb_build_object('id', ph.id, 'storage_path', ph.storage_path, 'position', ph.position,
                                                       'width', ph.width, 'height', ph.height) order by ph.position)
                   from public.update_photos ph where ph.update_id = u.id), '[]'::jsonb),
         r.read_at, coalesce(r.listened_ms, 0), x.emoji
  from public.updates u
  cross join week w
  join public.profiles p on p.id = u.author_id
  left join public.reads r on r.update_id = u.id and r.user_id = auth.uid()
  left join public.reactions x on x.update_id = u.id and x.user_id = auth.uid()
  where u.author_id <> auth.uid()
    and (
      u.week_start = w.current_week
      or (u.week_start = w.current_week - 7 and r.read_at is null and u.posted_at > now() - interval '4 days'
          and not exists (select 1 from public.updates newer where newer.author_id = u.author_id and newer.week_start = w.current_week))
    )
  order by (r.read_at is not null), u.posted_at desc
$$;
grant execute on function public.feed() to authenticated;

-- Marks an update read (first open) and records how far into the memo the reader got.
create or replace function public.mark_read(target uuid, listened int default 0) returns void
language sql security invoker set search_path = '' as $$
  insert into public.reads (update_id, user_id, listened_ms) values (target, auth.uid(), greatest(listened, 0))
  on conflict (update_id, user_id) do update set listened_ms = greatest(public.reads.listened_ms, excluded.listened_ms)
$$;
grant execute on function public.mark_read(uuid, int) to authenticated;

-- ============================================================
-- Replies
-- ============================================================

create or replace function public.open_thread(other uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  thread uuid;
begin
  if not private.is_friend(me, other) then raise exception 'You can only message friends' using errcode = '42501'; end if;
  insert into public.threads (user_a, user_b) values (least(me, other), greatest(me, other))
  on conflict (user_a, user_b) do nothing;
  select id into thread from public.threads where user_a = least(me, other) and user_b = greatest(me, other);
  return thread;
end;
$$;
grant execute on function public.open_thread(uuid) to authenticated;

create or replace function public.inbox()
returns table (thread_id uuid, other_id uuid, other_name text, last_body text, last_at timestamptz, last_from_me boolean, unread int)
language sql stable security invoker set search_path = '' as $$
  select t.id, o.id, o.display_name, m.body, m.created_at, m.sender_id = auth.uid(),
         (select count(*)::int from public.messages u
          where u.thread_id = t.id and u.sender_id <> auth.uid()
            and u.created_at > coalesce((select tr.last_read_at from public.thread_reads tr where tr.thread_id = t.id and tr.user_id = auth.uid()), '-infinity'))
  from public.threads t
  join public.profiles o on o.id = case when t.user_a = auth.uid() then t.user_b else t.user_a end
  join lateral (select * from public.messages mm where mm.thread_id = t.id order by mm.created_at desc limit 1) m on true
  where auth.uid() in (t.user_a, t.user_b)
  order by m.created_at desc
$$;
grant execute on function public.inbox() to authenticated;

create or replace function public.mark_thread_read(target uuid) returns void
language sql security invoker set search_path = '' as $$
  insert into public.thread_reads (thread_id, user_id, last_read_at) values (target, auth.uid(), now())
  on conflict (thread_id, user_id) do update set last_read_at = now()
$$;
grant execute on function public.mark_thread_read(uuid) to authenticated;

-- ============================================================
-- Share links and invites
-- ============================================================

-- A link to one update, readable without an account until it expires. People who join the
-- app from it are connected to the author and added to `circle` (PRD §10, "Bringing friends in").
create or replace function public.create_share_link(target uuid, circle uuid default null) returns public.share_links
language plpgsql security definer set search_path = '' as $$
declare
  result public.share_links;
begin
  if not private.is_update_author(target) then raise exception 'Not your update' using errcode = '42501'; end if;
  if circle is not null and not exists (select 1 from public.circles where id = circle and owner_id = auth.uid()) then
    raise exception 'Not your circle' using errcode = '42501';
  end if;
  select * into result from public.share_links
  where update_id = target and circle_id is not distinct from circle and expires_at > now() + interval '1 day'
  order by created_at desc limit 1;
  if found then return result; end if;
  insert into public.share_links (token, update_id, circle_id, expires_at)
  values (
    translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_'),
    target, circle, now() + make_interval(days => (private.config()).share_link_days)
  )
  returning * into result;
  return result;
end;
$$;
grant execute on function public.create_share_link(uuid, uuid) to authenticated;

create or replace function public.accept_invite(token text)
returns table (inviter_id uuid, inviter_name text, joined_circle boolean)
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  link public.share_links;
  inviter uuid;
  added boolean := false;
begin
  if me is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  select * into link from public.share_links s where s.token = accept_invite.token and s.expires_at > now();
  if not found then raise exception 'This link has expired' using errcode = 'P0002'; end if;
  select author_id into inviter from public.updates where id = link.update_id;
  if inviter = me then
    return query select inviter, (select display_name from public.profiles where id = inviter), false;
    return;
  end if;
  insert into public.friendships (user_a, user_b, status, requested_by)
  values (least(me, inviter), greatest(me, inviter), 'accepted', me)
  on conflict (user_a, user_b) do update set status = 'accepted';
  if link.circle_id is not null then
    insert into public.circle_members (circle_id, user_id) values (link.circle_id, me) on conflict do nothing;
    added := true;
  end if;
  return query select inviter, (select display_name from public.profiles where id = inviter), added;
end;
$$;
grant execute on function public.accept_invite(text) to authenticated;

-- ============================================================
-- Service role only (Edge Functions)
-- ============================================================

-- Users whose reminder time passed in the last hour (local time), who haven't posted for the
-- current week and haven't been reminded for it. The function runs every 15 minutes, so each
-- reminder normally goes out within 15 minutes; the hour of slack covers a missed run.
create or replace function public.due_reminders(at_time timestamptz default now())
returns table (user_id uuid, week_start date, tokens jsonb)
language sql stable security definer set search_path = '' as $$
  with local as (
    select p.id, p.timezone, p.reminder_weekday, p.reminder_time,
           at_time at time zone p.timezone as local_now,
           public.week_start_for(at_time, p.timezone, (private.config()).monday_cutoff_hour) as week
    from public.profiles p
    where p.reminders_enabled
  ), due as (
    select l.*,
           mod(
             (extract(dow from l.local_now)::int * 1440 + extract(hour from l.local_now)::int * 60 + extract(minute from l.local_now)::int)
             - (l.reminder_weekday * 1440 + extract(hour from l.reminder_time)::int * 60 + extract(minute from l.reminder_time)::int)
             + 10080, 10080) as minutes_late
    from local l
  )
  select d.id, d.week,
         (select jsonb_agg(jsonb_build_object('token', t.token, 'environment', t.environment)) from public.push_tokens t where t.user_id = d.id)
  from due d
  where d.minutes_late < 60
    and exists (select 1 from public.push_tokens t where t.user_id = d.id)
    and not exists (select 1 from public.updates u where u.author_id = d.id and u.week_start = d.week)
    and not exists (select 1 from public.reminder_log r where r.user_id = d.id and r.week_start = d.week)
$$;
revoke execute on function public.due_reminders(timestamptz) from public, anon, authenticated;
grant execute on function public.due_reminders(timestamptz) to service_role;

create or replace function public.take_storage_garbage(max_rows int default 500)
returns table (bucket text, path text)
language sql security definer set search_path = '' as $$
  delete from private.storage_garbage g
  where (g.bucket, g.path) in (select bucket, path from private.storage_garbage order by queued_at limit max_rows)
  returning g.bucket, g.path
$$;
revoke execute on function public.take_storage_garbage(int) from public, anon, authenticated;
grant execute on function public.take_storage_garbage(int) to service_role;
