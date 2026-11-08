-- 0.4 Storage for beta clients: members (memohub.members via memohub_api.is_member()) may upload
-- new objects to bucket `files` and read them (download, signed URLs). No update (no overwrite or
-- upsert: duplicates go through check_upload) and no delete: removal stays with the owner
-- (forget + storage rm, scripts/storage-gc.sh). Other buckets are untouched.

create policy memohub_members_upload on storage.objects
  for insert to authenticated
  with check (bucket_id = 'files' and memohub_api.is_member());

create policy memohub_members_read on storage.objects
  for select to authenticated
  using (bucket_id = 'files' and memohub_api.is_member());
