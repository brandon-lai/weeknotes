-- Per-user daily quotas for the Edge Functions that spend money (hosted formatting and
-- transcription), and view counts for share links (the "share-link views that become
-- installs" metric).

create table private.quota_usage (
  user_id uuid not null,
  kind text not null,
  day date not null default current_date,
  used int not null default 0,
  primary key (user_id, kind, day)
);

-- Returns true and counts the call when the user is under `daily_limit` for `quota_kind` today.
create or replace function public.consume_quota(who uuid, quota_kind text, daily_limit int) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  now_used int;
begin
  insert into private.quota_usage (user_id, kind, day, used) values (who, quota_kind, current_date, 1)
  on conflict (user_id, kind, day) do update set used = private.quota_usage.used + 1
  returning used into now_used;
  return now_used <= daily_limit;
end;
$$;
revoke execute on function public.consume_quota(uuid, text, int) from public, anon, authenticated;
grant execute on function public.consume_quota(uuid, text, int) to service_role;

alter table public.share_links add column views int not null default 0;

create or replace function public.count_share_view(link text) returns void
language sql security definer set search_path = '' as $$
  update public.share_links set views = views + 1 where token = link
$$;
revoke execute on function public.count_share_view(text) from public, anon, authenticated;
grant execute on function public.count_share_view(text) to service_role;

-- The sweep puts files back when Storage refuses to delete them, so the next run retries.
create or replace function public.requeue_storage_garbage(bucket_name text, paths text[]) returns void
language sql security definer set search_path = '' as $$
  insert into private.storage_garbage (bucket, path)
  select bucket_name, p from unnest(paths) p
  on conflict do nothing
$$;
revoke execute on function public.requeue_storage_garbage(text, text[]) from public, anon, authenticated;
grant execute on function public.requeue_storage_garbage(text, text[]) to service_role;
