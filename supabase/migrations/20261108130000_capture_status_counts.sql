-- capture_status(): count captures per source and device from the journal itself.
-- capture_sources.items_total only grew with the first batch of a run, so it under-counted.
create or replace function memohub.capture_status()
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select jsonb_build_object(
    'sources', coalesce((select jsonb_agg(jsonb_build_object(
        'source', s.source, 'device', s.device, 'last_scan_at', s.last_scan_at,
        'last_ok_at', s.last_ok_at, 'last_error', s.last_error, 'last_error_at', s.last_error_at,
        'captures', (select count(*) from captures c where c.source = s.source and c.device = s.device),
        'last_capture_at', (select max(c.event_at) from captures c where c.source = s.source and c.device = s.device))
        order by s.source, s.device) from capture_sources s), '[]'),
    'captures', (select count(*) from captures),
    'chats', (select count(distinct chat_ref) from captures),
    'suppressed', (select count(*) from suppressed_chats),
    'journal_bytes', pg_total_relation_size('memohub.captures'),
    'database_bytes', pg_database_size(current_database()));
$$;
revoke execute on function memohub.capture_status() from public;
