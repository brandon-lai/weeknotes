-- Weeknotes schema (PRD §12). Row level security is on for every table; the access rules
-- live in 20261026000002_access.sql. Tables the app writes through RPCs only (friendships,
-- threads) have no direct write grants.

create extension if not exists pgcrypto with schema extensions;

-- Not exposed through the API: secrets, queues, rate limits.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.secrets (
  name text primary key,
  value text not null
);

-- Pepper for phone hashes: a stolen profiles table can't be reversed by hashing every number.
insert into private.secrets (name, value)
values ('phone_pepper', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (name) do nothing;

create or replace function private.valid_timezone(tz text) returns boolean
language sql stable as $$
  select exists (select 1 from pg_timezone_names where name = tz)
$$;

-- Product flags that change without an app release (PRD §15 open questions).
create table public.app_config (
  id boolean primary key default true check (id),
  require_post_to_read boolean not null default false,
  monday_cutoff_hour int not null default 12 check (monday_cutoff_hour between 0 and 23),
  share_link_days int not null default 30 check (share_link_days between 1 and 365),
  app_store_url text
);
insert into public.app_config default values;

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  -- HMAC(pepper, sha256(E.164)), set by trigger from the verified phone on auth.users
  phone_hash text unique,
  timezone text not null default 'America/New_York' check (private.valid_timezone(timezone)),
  reminder_weekday int not null default 0 check (reminder_weekday between 0 and 6), -- 0 = Sunday
  reminder_time time not null default '18:00',
  reminders_enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.friendships (
  user_a uuid not null references public.profiles on delete cascade,
  user_b uuid not null references public.profiles on delete cascade,
  status text not null check (status in ('pending', 'accepted')),
  requested_by uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b),
  check (requested_by in (user_a, user_b))
);
create index friendships_user_b on public.friendships (user_b);

create table public.circles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  created_at timestamptz not null default now(),
  unique (owner_id, name)
);

create table public.circle_members (
  circle_id uuid not null references public.circles on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  primary key (circle_id, user_id)
);
create index circle_members_user on public.circle_members (user_id);

create table public.updates (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles on delete cascade,
  week_start date not null,          -- Monday of the week, author's time zone (set by trigger)
  prompt text check (char_length(prompt) <= 120),
  body_text text check (char_length(body_text) <= 20000),
  body_raw_transcript text check (char_length(body_raw_transcript) <= 40000),
  -- How it was written, for the "share of updates by mode" metric
  composed_with text[] not null default '{}' check (composed_with <@ array['typed', 'dictated', 'memo']),
  compose_ms int check (compose_ms >= 0),
  posted_at timestamptz not null default now(),
  edited_at timestamptz,
  unique (author_id, week_start)
);
create index updates_week on public.updates (week_start, posted_at desc);

create table public.voice_memos (
  id uuid primary key default gen_random_uuid(),
  update_id uuid not null unique references public.updates on delete cascade,
  storage_path text not null,
  duration_ms int not null check (duration_ms between 1 and 305000),
  waveform jsonb not null check (jsonb_typeof(waveform) = 'array' and jsonb_array_length(waveform) <= 200),
  transcript_raw text,
  transcript_clean text,
  engine_id text,
  created_at timestamptz not null default now()
);

create table public.update_photos (
  id uuid primary key default gen_random_uuid(),
  update_id uuid not null references public.updates on delete cascade,
  storage_path text not null,
  position int not null check (position between 0 and 3),
  width int,
  height int,
  unique (update_id, position)
);

create table public.update_audiences (
  update_id uuid not null references public.updates on delete cascade,
  circle_id uuid not null references public.circles on delete cascade,
  primary key (update_id, circle_id)
);
create index update_audiences_circle on public.update_audiences (circle_id);

create table public.reactions (
  update_id uuid not null references public.updates on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (update_id, user_id)
);

create table public.reads (
  update_id uuid not null references public.updates on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  read_at timestamptz not null default now(),
  listened_ms int not null default 0 check (listened_ms >= 0),
  primary key (update_id, user_id)
);

create table public.threads (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references public.profiles on delete cascade,
  user_b uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_a, user_b),
  check (user_a < user_b)
);

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.threads on delete cascade,
  sender_id uuid not null references public.profiles on delete cascade,
  update_id uuid references public.updates on delete set null,
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index messages_thread on public.messages (thread_id, created_at);

-- When each participant last opened a thread, for the inbox's unread dots.
create table public.thread_reads (
  thread_id uuid not null references public.threads on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);

create table public.share_links (
  token text primary key,
  update_id uuid not null references public.updates on delete cascade,
  -- People who join from this link are added to this circle of the author's
  circle_id uuid references public.circles on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index share_links_update on public.share_links (update_id);

create table public.user_dictionary (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles on delete cascade,
  written text not null check (char_length(btrim(written)) between 1 and 60),
  sounds_like text[] not null default '{}' check (cardinality(sounds_like) <= 20),
  source text not null default 'manual' check (source in ('manual', 'learned')),
  created_at timestamptz not null default now(),
  unique (user_id, written)
);
-- Friends' names are added to the vocabulary at runtime from friendships; they are not copied here.

-- APNs device tokens for weekly reminders.
create table public.push_tokens (
  token text primary key check (token ~ '^[0-9a-f]{64,200}$'),
  user_id uuid not null references public.profiles on delete cascade,
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  updated_at timestamptz not null default now()
);
create index push_tokens_user on public.push_tokens (user_id);

-- One reminder per user per week, written by the reminders function.
create table public.reminder_log (
  user_id uuid not null references public.profiles on delete cascade,
  week_start date not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, week_start)
);

-- Storage objects whose rows are gone; the sweep function deletes the files.
create table private.storage_garbage (
  bucket text not null,
  path text not null,
  queued_at timestamptz not null default now(),
  primary key (bucket, path)
);

-- Contact matching calls per user per day.
create table private.match_log (
  user_id uuid not null,
  day date not null default current_date,
  calls int not null default 0,
  primary key (user_id, day)
);
