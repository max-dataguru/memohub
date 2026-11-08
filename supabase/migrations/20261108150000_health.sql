-- A3 completeness report, database side: one call per database tells what was captured and saved
-- lately, which capture sources are quiet or failing, and how full the database is.
-- scripts/health.py adds what only the Mac knows (scanner spool, backups, launchd jobs).
create function memohub.health(p_days int default 7)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  with src as (
    select s.source, s.device, s.last_scan_at, s.last_ok_at, s.last_error, s.last_error_at,
           (select count(*) from captures c where c.source = s.source and c.device = s.device) as captures,
           (select count(*) from captures c where c.source = s.source and c.device = s.device
              and c.created_at > now() - make_interval(days => p_days)) as recent,
           (select max(c.event_at) from captures c where c.source = s.source and c.device = s.device) as last_capture_at
      from capture_sources s
    union all
    -- Shortcut thoughts have no scanner row: report each device that has a key or thoughts.
    select 'shortcut', d.device, null, (select max(c.created_at) from captures c where c.source = 'shortcut' and c.device = d.device),
           null, null,
           (select count(*) from captures c where c.source = 'shortcut' and c.device = d.device),
           (select count(*) from captures c where c.source = 'shortcut' and c.device = d.device
              and c.created_at > now() - make_interval(days => p_days)),
           (select max(c.event_at) from captures c where c.source = 'shortcut' and c.device = d.device)
      from (select device from device_keys where revoked_at is null
            union select device from captures where source = 'shortcut') d
  )
  select jsonb_build_object(
    'tier', tier(),
    'days', p_days,
    'generated_at', now(),
    'capture_sources', coalesce((select jsonb_agg(jsonb_build_object(
        'source', source, 'device', device, 'captures', captures, 'recent', recent,
        'last_scan_at', last_scan_at, 'last_ok_at', last_ok_at, 'last_capture_at', last_capture_at,
        'error', case when last_error_at is not null and (last_ok_at is null or last_error_at >= last_ok_at)
                      then last_error end,
        'quiet_hours', case when source <> 'shortcut' and last_scan_at is not null
                            then round(extract(epoch from now() - last_scan_at) / 3600) end)
        order by source, device) from src), '[]'),
    'notes', jsonb_build_object(
      'active', (select count(*) from notes where status = 'active'),
      'saved_recently', (select count(*) from notes where created_at > now() - make_interval(days => p_days)),
      'by_source', coalesce((select jsonb_object_agg(k, n) from (
          select coalesce(source, '?') || '/' || coalesce(device, '?') as k, count(*) as n
            from notes where created_at > now() - make_interval(days => p_days)
           group by 1) x), '{}'),
      'last_saved_at', (select max(created_at) from notes),
      'without_embedding', (select count(*) from notes n where n.status = 'active'
                              and not exists (select 1 from note_embeddings e where e.note_id = n.id))),
    'journal', jsonb_build_object(
      'captures', (select count(*) from captures),
      'chats', (select count(distinct chat_ref) from captures),
      'suppressed_chats', (select count(*) from suppressed_chats),
      'bytes', pg_total_relation_size('memohub.captures')),
    'device_keys', coalesce((select jsonb_agg(jsonb_build_object('device', device, 'last_used_at', last_used_at, 'uses', uses))
                               from device_keys where revoked_at is null), '[]'),
    'database_bytes', pg_database_size(current_database()),
    'database_limit_bytes', _cfg_bigint('database_limit_bytes', 524288000),
    'storage', storage_usage());
$$;
revoke execute on function memohub.health(int) from public;
