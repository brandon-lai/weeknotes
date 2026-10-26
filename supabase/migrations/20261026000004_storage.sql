-- Private buckets for voice memos and photos (PRD §8, "Storage and privacy").
-- Paths are `{author_id}/{update_id}/{file}`. Authors write only in their own folder; anyone
-- who can read the update can read (and so create short-lived signed URLs for) its files.
-- Share links get signed URLs from the share Edge Function instead.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('memos', 'memos', false, 5242880, array['audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac']),
  ('photos', 'photos', false, 10485760, array['image/jpeg', 'image/heic', 'image/png'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.storage_update_id(object_name text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return (string_to_array(object_name, '/'))[2]::uuid;
exception when others then
  return null;
end;
$$;

create policy "media: authors upload to their own folder" on storage.objects for insert to authenticated
with check (
  bucket_id in ('memos', 'photos')
  and (string_to_array(name, '/'))[1] = auth.uid()::text
  and private.storage_update_id(name) is not null
);

create policy "media: readable with the update" on storage.objects for select to authenticated
using (
  bucket_id in ('memos', 'photos')
  and (
    (string_to_array(name, '/'))[1] = auth.uid()::text
    or public.can_read_update(private.storage_update_id(name))
  )
);

create policy "media: authors delete their files" on storage.objects for delete to authenticated
using (
  bucket_id in ('memos', 'photos')
  and (string_to_array(name, '/'))[1] = auth.uid()::text
);
