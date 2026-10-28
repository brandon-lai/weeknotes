-- Local-first (2026-10-28): the app works with no account. Weeks are written and kept on the
-- phone; an account adds friends, sharing and a private backup.
--
-- 1. Anonymous sessions. A signed-out app gets an anonymous Supabase session so it can use the
--    hosted formatting and transcription fallbacks (with lower quotas). Anonymous users must not
--    reach anything social: they can't create a profile, and without a profile every social
--    table is out of reach through its foreign keys. They also can't upload files.
-- 2. Backfill. Signing in uploads the weeks already written on the phone, so an update can be
--    inserted for a past week, keeping its original week and time.
-- 3. Reminders move to local notifications on the phone (they work without an account), so the
--    server reminder job is unscheduled. The function stays for later use.

create or replace function private.is_anonymous() returns boolean
language sql stable set search_path = '' as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

drop policy "profiles: insert self" on public.profiles;
create policy "profiles: insert self" on public.profiles for insert to authenticated
  with check (id = auth.uid() and not private.is_anonymous());

drop policy "media: authors upload to their own folder" on storage.objects;
create policy "media: authors upload to their own folder" on storage.objects for insert to authenticated
with check (
  bucket_id in ('memos', 'photos')
  and not private.is_anonymous()
  and (string_to_array(name, '/'))[1] = auth.uid()::text
  and private.storage_update_id(name) is not null
);

-- Backfill: the client may say which week an update belongs to and when it was written.
-- The week must be a Monday no later than the current week anywhere on Earth (UTC+14), and
-- the time can't be in the future.
grant insert (week_start, posted_at) on public.updates to authenticated;

create or replace function private.updates_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  current_week date;
begin
  if tg_op = 'INSERT' then
    new.author_id := auth.uid();
    new.edited_at := null;
    select public.week_start_for(now(), p.timezone, (private.config()).monday_cutoff_hour)
      into current_week from public.profiles p where p.id = new.author_id;
    if current_week is null then
      raise exception 'Set up your profile before posting' using errcode = 'P0001';
    end if;
    if new.week_start is null
       or extract(isodow from new.week_start) <> 1
       or new.week_start > public.week_start_for(now() + interval '14 hours', 'UTC', 0) then
      new.week_start := current_week;
    end if;
    if new.posted_at is null or new.posted_at > now() + interval '5 minutes' then
      new.posted_at := now();
    end if;
  else
    new.author_id := old.author_id;
    new.week_start := old.week_start;
    new.posted_at := old.posted_at;
    if (new.body_text, new.prompt, new.body_raw_transcript) is distinct from (old.body_text, old.prompt, old.body_raw_transcript) then
      new.edited_at := now();
    end if;
  end if;
  return new;
end;
$$;

drop function public.publish_update(uuid, text, text, text, text[], int, uuid[], jsonb, jsonb);

-- Creates or edits an update with its audience and media in one transaction. The app picks the
-- id up front so it can upload files to `{user}/{update}/...` first. An empty `circles` array is
-- allowed: the update is a private backup. p_week_start / p_posted_at backfill weeks written
-- before signing in (see updates_stamp for the limits).
create or replace function public.publish_update(
  p_id uuid,
  p_prompt text,
  p_body text,
  p_raw_transcript text,
  p_composed_with text[],
  p_compose_ms int,
  p_circles uuid[],
  p_memo jsonb default null,
  p_photos jsonb default '[]',
  p_week_start date default null,
  p_posted_at timestamptz default null
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
    insert into public.updates (id, prompt, body_text, body_raw_transcript, composed_with, compose_ms, week_start, posted_at)
    values (p_id, p_prompt, nullif(btrim(p_body), ''), p_raw_transcript, p_composed_with, p_compose_ms, p_week_start, p_posted_at)
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
grant execute on function public.publish_update(uuid, text, text, text, text[], int, uuid[], jsonb, jsonb, date, timestamptz) to authenticated;

-- Reminders are local notifications now
select cron.unschedule(jobid) from cron.job where jobname = 'weeknotes-reminders';
