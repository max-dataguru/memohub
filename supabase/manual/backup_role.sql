-- Read-only role for the nightly pg_dump from a backup host. Run once in the Supabase
-- SQL Editor, replacing the password placeholder there; never commit the real one.

create role memohub_backup login password 'CHANGE-ME-IN-SQL-EDITOR';

grant usage on schema memohub to memohub_backup;
grant select on all tables in schema memohub to memohub_backup;
alter default privileges in schema memohub grant select on tables to memohub_backup;

-- RLS is on with no policies; the backup role gets read-only visibility.
-- pg_dump must run with --enable-row-security for these policies to apply.
create policy backup_read on memohub.spaces   for select to memohub_backup using (true);
create policy backup_read on memohub.projects for select to memohub_backup using (true);
create policy backup_read on memohub.notes    for select to memohub_backup using (true);
create policy backup_read on memohub.config   for select to memohub_backup using (true);
create policy backup_read on memohub.files    for select to memohub_backup using (true);
create policy backup_read on memohub.guides   for select to memohub_backup using (true);
create policy backup_read on memohub.entities for select to memohub_backup using (true);
create policy backup_read on memohub.note_entities for select to memohub_backup using (true);
create policy backup_read on memohub.entity_edges for select to memohub_backup using (true);
create policy backup_read on memohub.note_embeddings for select to memohub_backup using (true);
create policy backup_read on memohub.forgotten for select to memohub_backup using (true);
create policy backup_read on memohub.captures for select to memohub_backup using (true);
create policy backup_read on memohub.suppressed_chats for select to memohub_backup using (true);
create policy backup_read on memohub.capture_sources for select to memohub_backup using (true);
create policy backup_read on memohub.memory_candidates for select to memohub_backup using (true);
create policy backup_read on memohub.candidate_sources for select to memohub_backup using (true);
create policy backup_read on memohub.distill_runs for select to memohub_backup using (true);
create policy backup_read on memohub.distill_progress for select to memohub_backup using (true);
