-- Access rules (PRD §12): who can read and write what, and the RPCs that do multi-row work.
-- Every function is `security invoker` (RLS applies) unless it says why it isn't, and every
-- `security definer` function pins `search_path` and checks `auth.uid()` itself.

-- Start from nothing, then grant per table.
revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

alter table public.app_config enable row level security;
alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.circles enable row level security;
alter table public.circle_members enable row level security;
alter table public.updates enable row level security;
alter table public.voice_memos enable row level security;
alter table public.update_photos enable row level security;
alter table public.update_audiences enable row level security;
alter table public.reactions enable row level security;
alter table public.reads enable row level security;
alter table public.threads enable row level security;
alter table public.messages enable row level security;
alter table public.thread_reads enable row level security;
alter table public.share_links enable row level security;
alter table public.user_dictionary enable row level security;
alter table public.push_tokens enable row level security;
alter table public.reminder_log enable row level security;

-- ============================================================
-- Helpers
-- ============================================================

create or replace function private.config() returns public.app_config
language sql stable security definer set search_path = '' as $$
  select * from public.app_config where id
$$;

-- Week boundaries: Monday 00:00 to Sunday 23:59 local, and posts before Monday `cutoff`:00
-- count toward the previous week. Same rule as Week.start(for:in:) in the app.
create or replace function public.week_start_for(at_time timestamptz, tz text, cutoff int default 12) returns date
language sql stable set search_path = '' as $$
  select date_trunc('week', local)::date
       - case when extract(isodow from local) = 1 and extract(hour from local) < cutoff then 7 else 0 end
  from (select at_time at time zone tz as local) l
$$;

create or replace function public.my_week_start() returns date
language sql stable security definer set search_path = '' as $$
  select public.week_start_for(now(), coalesce(p.timezone, 'UTC'), (private.config()).monday_cutoff_hour)
  from (select 1) one
  left join public.profiles p on p.id = auth.uid()
$$;

create or replace function private.is_friend(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f
    where f.user_a = least(a, b) and f.user_b = greatest(a, b) and f.status = 'accepted'
  )
$$;

-- The visibility rule: the author, or an accepted friend in one of the circles the update was
-- shared with. With `require_post_to_read` on, readers must also have posted that week.
-- security definer so policies can call it without recursing through RLS on updates.
create or replace function public.can_read_update(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.updates u
    where u.id = target
      and auth.uid() is not null
      and (
        u.author_id = auth.uid()
        or (
          exists (
            select 1
            from public.update_audiences ua
            join public.circles c on c.id = ua.circle_id and c.owner_id = u.author_id
            join public.circle_members cm on cm.circle_id = ua.circle_id
            where ua.update_id = u.id and cm.user_id = auth.uid()
          )
          and private.is_friend(u.author_id, auth.uid())
          and (
            not (private.config()).require_post_to_read
            or exists (select 1 from public.updates mine where mine.author_id = auth.uid() and mine.week_start = u.week_start)
          )
        )
      )
  )
$$;

create or replace function private.is_update_author(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.updates where id = target and author_id = auth.uid())
$$;

create or replace function private.in_thread(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.threads t where t.id = target and auth.uid() in (t.user_a, t.user_b))
$$;

-- ============================================================
-- Phone hashes (contact matching)
-- ============================================================

-- sha256 hex of the E.164 number: what the app computes on device (PhoneNumber.hash).
create or replace function private.phone_digest(phone text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest('+' || regexp_replace(phone, '[^0-9]', '', 'g'), 'sha256'), 'hex')
$$;

create or replace function private.peppered(client_hash text) returns text
language sql stable security definer set search_path = '' as $$
  select encode(extensions.hmac(lower(client_hash), (select value from private.secrets where name = 'phone_pepper'), 'sha256'), 'hex')
$$;

-- Only a phone the user verified (Supabase Auth phone change + OTP) is ever matchable, so
-- nobody can claim someone else's number.
create or replace function private.verified_phone_hash(user_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case when u.phone_confirmed_at is not null and coalesce(u.phone, '') <> ''
              then private.peppered(private.phone_digest(u.phone)) end
  from auth.users u where u.id = user_id
$$;

create or replace function private.sync_phone_hash() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  next_hash text := private.verified_phone_hash(new.id);
begin
  if next_hash is not null then
    -- A number that moved to a new owner stops matching the old one
    update public.profiles set phone_hash = null where phone_hash = next_hash and id <> new.id;
  end if;
  update public.profiles set phone_hash = next_hash where id = new.id and phone_hash is distinct from next_hash;
  return new;
end;
$$;

create trigger sync_phone_hash
after insert or update of phone, phone_confirmed_at on auth.users
for each row execute function private.sync_phone_hash();

create or replace function private.profile_defaults() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.phone_hash := private.verified_phone_hash(new.id);
  if new.phone_hash is not null then
    update public.profiles set phone_hash = null where phone_hash = new.phone_hash and id <> new.id;
  end if;
  return new;
end;
$$;

create trigger profile_defaults before insert on public.profiles
for each row execute function private.profile_defaults();

-- ============================================================
-- Table rules
-- ============================================================

grant select on public.app_config to anon, authenticated;
create policy "app_config is readable" on public.app_config for select using (true);

-- Profiles: you read your own and those of people you have a friendship (or request) with.
-- phone_hash is never selectable; the reminder schedule comes from my_profile().
grant select (id, display_name, timezone, created_at) on public.profiles to authenticated;
grant insert (id, display_name, timezone, reminder_weekday, reminder_time, reminders_enabled) on public.profiles to authenticated;
grant update (display_name, timezone, reminder_weekday, reminder_time, reminders_enabled) on public.profiles to authenticated;
create policy "profiles: self and connections" on public.profiles for select to authenticated using (
  id = auth.uid()
  or exists (
    select 1 from public.friendships f
    where f.user_a = least(id, auth.uid()) and f.user_b = greatest(id, auth.uid())
  )
);
create policy "profiles: insert self" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles: update self" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Friendships: visible to both people; changed only through the RPCs below.
grant select on public.friendships to authenticated;
create policy "friendships: participants" on public.friendships for select to authenticated using (auth.uid() in (user_a, user_b));

-- Circles are the owner's private labels; members don't see them.
grant select, insert, update, delete on public.circles to authenticated;
create policy "circles: owner" on public.circles for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

grant select, insert, delete on public.circle_members to authenticated;
create policy "circle_members: owner reads" on public.circle_members for select to authenticated using (
  exists (select 1 from public.circles c where c.id = circle_id and c.owner_id = auth.uid())
);
create policy "circle_members: owner adds friends" on public.circle_members for insert to authenticated with check (
  exists (select 1 from public.circles c where c.id = circle_id and c.owner_id = auth.uid())
  and private.is_friend(auth.uid(), user_id)
);
create policy "circle_members: owner removes" on public.circle_members for delete to authenticated using (
  exists (select 1 from public.circles c where c.id = circle_id and c.owner_id = auth.uid())
);

-- Updates: the visibility rule above; only the author writes.
grant select on public.updates to authenticated;
grant insert (id, prompt, body_text, body_raw_transcript, composed_with, compose_ms) on public.updates to authenticated;
grant update (prompt, body_text, body_raw_transcript, composed_with, compose_ms) on public.updates to authenticated;
grant delete on public.updates to authenticated;
-- The author check comes first and reads the row itself: can_read_update() sees the table as of
-- the start of the statement, so it can't see a row that `insert ... returning` just wrote.
create policy "updates: readable" on public.updates for select to authenticated using (author_id = auth.uid() or public.can_read_update(id));
create policy "updates: author inserts" on public.updates for insert to authenticated with check (author_id = auth.uid());
create policy "updates: author edits" on public.updates for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy "updates: author deletes" on public.updates for delete to authenticated using (author_id = auth.uid());

-- The server decides the author and the week; edits are stamped.
create or replace function private.updates_stamp() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.author_id := auth.uid();
    new.posted_at := now();
    new.edited_at := null;
    select public.week_start_for(now(), p.timezone, (private.config()).monday_cutoff_hour)
      into new.week_start from public.profiles p where p.id = new.author_id;
    if new.week_start is null then
      raise exception 'Set up your profile before posting' using errcode = 'P0001';
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

create trigger updates_stamp before insert or update on public.updates
for each row execute function private.updates_stamp();

-- Media rows follow their update.
grant select, insert, update, delete on public.voice_memos to authenticated;
create policy "voice_memos: readable" on public.voice_memos for select to authenticated using (public.can_read_update(update_id));
create policy "voice_memos: author writes" on public.voice_memos for all to authenticated
  using (private.is_update_author(update_id)) with check (private.is_update_author(update_id) and storage_path like auth.uid()::text || '/%');

grant select, insert, update, delete on public.update_photos to authenticated;
create policy "update_photos: readable" on public.update_photos for select to authenticated using (public.can_read_update(update_id));
create policy "update_photos: author writes" on public.update_photos for all to authenticated
  using (private.is_update_author(update_id)) with check (private.is_update_author(update_id) and storage_path like auth.uid()::text || '/%');

-- Audiences: the author's own circles only. Readers never see who else it went to.
grant select, insert, delete on public.update_audiences to authenticated;
create policy "update_audiences: author" on public.update_audiences for all to authenticated
  using (private.is_update_author(update_id))
  with check (
    private.is_update_author(update_id)
    and exists (select 1 from public.circles c where c.id = circle_id and c.owner_id = auth.uid())
  );

-- Reactions: one per reader per update; seen only by the reactor and the author (no public counts).
grant select, insert, update, delete on public.reactions to authenticated;
create policy "reactions: reactor and author read" on public.reactions for select to authenticated
  using (user_id = auth.uid() or private.is_update_author(update_id));
create policy "reactions: readers react" on public.reactions for insert to authenticated
  with check (user_id = auth.uid() and public.can_read_update(update_id) and not private.is_update_author(update_id));
create policy "reactions: change own" on public.reactions for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.can_read_update(update_id));
create policy "reactions: remove own" on public.reactions for delete to authenticated using (user_id = auth.uid());

-- Reads and listening progress: written by the reader, visible to the reader and the author.
grant select, insert, update on public.reads to authenticated;
create policy "reads: reader and author" on public.reads for select to authenticated
  using (user_id = auth.uid() or private.is_update_author(update_id));
create policy "reads: record own" on public.reads for insert to authenticated
  with check (user_id = auth.uid() and public.can_read_update(update_id));
create policy "reads: update own" on public.reads for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Threads and messages: one-to-one, friends only, created through open_thread().
grant select on public.threads to authenticated;
create policy "threads: participants" on public.threads for select to authenticated using (auth.uid() in (user_a, user_b));

grant select, insert on public.messages to authenticated;
create policy "messages: participants read" on public.messages for select to authenticated using (private.in_thread(thread_id));
create policy "messages: participants send" on public.messages for insert to authenticated with check (
  sender_id = auth.uid()
  and private.in_thread(thread_id)
  and (update_id is null or public.can_read_update(update_id))
);

grant select, insert, update on public.thread_reads to authenticated;
create policy "thread_reads: own" on public.thread_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and private.in_thread(thread_id));

-- Share links: the author manages them; resolving a token is the share Edge Function's job.
grant select, delete on public.share_links to authenticated;
create policy "share_links: author" on public.share_links for select to authenticated using (private.is_update_author(update_id));
create policy "share_links: author deletes" on public.share_links for delete to authenticated using (private.is_update_author(update_id));

grant select, insert, update, delete on public.user_dictionary to authenticated;
create policy "user_dictionary: own" on public.user_dictionary for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, update, delete on public.push_tokens to authenticated;
create policy "push_tokens: own" on public.push_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- reminder_log: service role only (RLS on, no policies).

-- Deleting media rows (directly or by cascade) queues their files for the sweep function.
create or replace function private.queue_storage_garbage() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.storage_garbage (bucket, path)
  values (case tg_table_name when 'voice_memos' then 'memos' else 'photos' end, old.storage_path)
  on conflict do nothing;
  return old;
end;
$$;

create trigger voice_memos_garbage after delete on public.voice_memos
for each row execute function private.queue_storage_garbage();
create trigger update_photos_garbage after delete on public.update_photos
for each row execute function private.queue_storage_garbage();

-- A replaced memo or photo file is garbage too.
create or replace function private.queue_replaced_file() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.storage_path is distinct from old.storage_path then
    insert into private.storage_garbage (bucket, path)
    values (case tg_table_name when 'voice_memos' then 'memos' else 'photos' end, old.storage_path)
    on conflict do nothing;
  end if;
  return new;
end;
$$;

create trigger voice_memos_replaced after update on public.voice_memos
for each row execute function private.queue_replaced_file();
create trigger update_photos_replaced after update on public.update_photos
for each row execute function private.queue_replaced_file();
