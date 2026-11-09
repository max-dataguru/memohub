-- A4 distiller, database side. A job on the Mac (scripts/distill.py) reads finished journal chats,
-- asks a model for notes worth keeping and hands the parsed answer to _distill_record(), which
-- creates candidates through _propose(). Nothing leaves the database unless distill.allow lists
-- the source: the list is empty by default, so a fresh install distills nothing.
--
-- * distill_progress: one cursor per chat (event_at, seq, part, id of the last capture sent).
--   The journal itself is never changed. Three failures in a row mark the chat failed; it is
--   shown in health() and skipped until a person resets it.
-- * distill_runs: one row per job run with model, chats, candidates and list-price cost.
--   Three failed runs in a row set distill.paused; a person clears it.
-- * Every function here is owner-only: the job runs as the owner through the linked CLI.

insert into memohub.config (key, value) values
  ('distill.allow', '[]'),    -- [{"source": "claude-code", "project": null | "<project_hint>"}]
  ('distill.paused', 'false')
on conflict (key) do nothing;

create table memohub.distill_runs (
  id          uuid primary key default gen_random_uuid(),
  started_at  timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  status      text not null default 'running' check (status in ('running', 'done', 'failed')),
  model       text not null,
  chats       int not null default 0,
  candidates  int not null default 0,
  cost_usd    numeric not null default 0,
  error       text
);
create index distill_runs_started_idx on memohub.distill_runs (started_at desc);

create table memohub.distill_progress (
  chat_ref        text primary key,
  cursor_event_at timestamptz,
  cursor_seq      int,
  cursor_part     int,
  cursor_id       uuid,
  attempts        int not null default 0,
  status          text not null default 'ok' check (status in ('ok', 'failed')),
  last_error      text,
  updated_at      timestamptz not null default now()
);

alter table memohub.distill_runs enable row level security;
alter table memohub.distill_progress enable row level security;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.distill_runs, memohub.distill_progress from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.distill_runs, memohub.distill_progress to memohub_backup;
    create policy backup_read on memohub.distill_runs for select to memohub_backup using (true);
    create policy backup_read on memohub.distill_progress for select to memohub_backup using (true);
  end if;
end $$;

-- Exact match on source and, when given, on project_hint. No patterns.
create function memohub._distill_allowed(p_source text, p_project text)
returns boolean language sql stable set search_path = memohub, pg_catalog as $$
  select exists (
    select 1 from config c, jsonb_array_elements(c.value::jsonb) a
     where c.key = 'distill.allow' and jsonb_typeof(c.value::jsonb) = 'array'
       and a->>'source' = p_source
       and (a->>'project' is null or a->>'project' = p_project));
$$;

-- Read (p_value null) or replace the allow list. Entries: {"source": <capture source>,
-- "project": <exact project_hint> | null}.
create function memohub._distill_allow(p_value jsonb default null)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
begin
  if p_value is not null then
    if jsonb_typeof(p_value) <> 'array' or exists (
         select 1 from jsonb_array_elements(p_value) a
          where jsonb_typeof(a) <> 'object'
             or coalesce(a->>'source', '') not in ('claude-code', 'codex', 'meeting', 'claude-ai', 'chatgpt', 'shortcut')
             or exists (select 1 from jsonb_object_keys(a) k where k not in ('source', 'project'))
             or jsonb_typeof(coalesce(a->'project', 'null')) not in ('string', 'null')) then
      return jsonb_build_object('ok', false, 'error', 'bad_allow');
    end if;
    insert into config (key, value) values ('distill.allow', p_value::text)
    on conflict (key) do update set value = excluded.value;
  end if;
  return jsonb_build_object('ok', true, 'allow', (select value::jsonb from config where key = 'distill.allow'));
end $$;

-- Start a run. Refuses while paused, while another run is going, or when nothing is allowed.
-- A run left 'running' for longer than p_stale (a crashed job) is closed as failed.
create function memohub._distill_begin(p_model text, p_stale interval default '6 hours')
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('memohub.distill', 0));
  if coalesce((select value from config where key = 'distill.paused'), 'false') = 'true' then
    return jsonb_build_object('ok', false, 'error', 'paused');
  end if;
  if coalesce((select jsonb_array_length(value::jsonb) from config where key = 'distill.allow'), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_enabled');
  end if;
  update distill_runs set status = 'failed', finished_at = now(), error = 'lost'
   where status = 'running' and started_at < now() - p_stale;
  if exists (select 1 from distill_runs where status = 'running') then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;
  insert into distill_runs (model) values (coalesce(nullif(trim(p_model), ''), '?')) returning id into v_id;
  return jsonb_build_object('ok', true, 'run', v_id);
end $$;

-- Chats ready to distill: allowed, quiet for p_quiet, not suppressed or failed, with captures
-- after the cursor. Oldest first.
create function memohub._distill_pending(p_limit int default 10, p_quiet interval default '2 hours')
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  with chats as (
    select chat_ref, min(source) as source, max(project_hint) as project_hint, max(event_at) as last_at
      from captures group by chat_ref
  )
  select coalesce(jsonb_agg(jsonb_build_object('chat_ref', c.chat_ref, 'source', c.source,
                                               'project_hint', c.project_hint, 'last_at', c.last_at)
                            order by c.last_at), '[]')
    from (select c.* from chats c
            left join distill_progress p on p.chat_ref = c.chat_ref
           where c.last_at < now() - p_quiet
             and _distill_allowed(c.source, c.project_hint)
             and coalesce(p.status, 'ok') <> 'failed'
             and not exists (select 1 from suppressed_chats s where s.chat_ref = c.chat_ref)
             and exists (select 1 from captures x
                          where x.chat_ref = c.chat_ref
                            and (p.cursor_id is null
                                 or (x.event_at, x.seq, x.part, x.id)
                                    > (p.cursor_event_at, p.cursor_seq, p.cursor_part, p.cursor_id)))
           order by c.last_at
           limit greatest(p_limit, 0)) c;
$$;

-- What the job sends for one chat: captures after the cursor, oldest first, and the titles of
-- notes already saved from this chat (so the model does not propose them again).
create function memohub._distill_chat(p_chat_ref text, p_limit int default 3000)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select jsonb_build_object(
    'chat_ref', p_chat_ref,
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'role', x.role, 'event_at', x.event_at,
                                          'part', x.part, 'content', x.content)
                       order by x.event_at, x.seq, x.part, x.id)
        from (select c.* from captures c
                left join distill_progress p on p.chat_ref = c.chat_ref
               where c.chat_ref = p_chat_ref
                 and (p.cursor_id is null
                      or (c.event_at, c.seq, c.part, c.id)
                         > (p.cursor_event_at, p.cursor_seq, p.cursor_part, p.cursor_id))
               order by c.event_at, c.seq, c.part, c.id
               limit greatest(p_limit, 0)) x), '[]'),
    'saved_titles', coalesce((select jsonb_agg(n.title order by n.created_at) from notes n
                               where n.chat_ref = p_chat_ref and n.status = 'active'), '[]'));
$$;

-- Record one chat of a run: propose each candidate (all checks of _propose apply), then move the
-- cursor to the last capture sent. p_sent must be captures of this chat.
create function memohub._distill_record(p_run uuid, p_chat_ref text, p_sent uuid[],
                                        p_candidates jsonb default '[]', p_cost numeric default 0)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v_run   distill_runs;
  v_last  captures;
  v_c     jsonb;
  v_r     jsonb;
  v_ids   jsonb := '[]';
  v_errs  jsonb := '[]';
begin
  select * into v_run from distill_runs where id = p_run for update;
  if not found or v_run.status <> 'running' then
    return jsonb_build_object('ok', false, 'error', 'run_not_running');
  end if;
  if coalesce(cardinality(p_sent), 0) = 0
     or (select count(*) from captures where id = any (p_sent) and chat_ref = p_chat_ref)
        <> (select count(distinct s) from unnest(p_sent) s) then
    return jsonb_build_object('ok', false, 'error', 'bad_sent');
  end if;
  if jsonb_typeof(coalesce(p_candidates, '[]')) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'bad_candidates');
  end if;

  for v_c in select * from jsonb_array_elements(coalesce(p_candidates, '[]')) loop
    v_r := _propose(p_run, v_c || jsonb_build_object('model', v_run.model), p_sent);
    if (v_r->>'ok')::boolean then
      v_ids := v_ids || to_jsonb(v_r->>'id');
    else
      v_errs := v_errs || to_jsonb(v_r->>'error');
    end if;
  end loop;

  select * into v_last from captures where id = any (p_sent)
   order by event_at desc, seq desc, part desc, id desc limit 1;
  insert into distill_progress as p (chat_ref, cursor_event_at, cursor_seq, cursor_part, cursor_id)
  values (p_chat_ref, v_last.event_at, v_last.seq, v_last.part, v_last.id)
  on conflict (chat_ref) do update
     set cursor_event_at = excluded.cursor_event_at, cursor_seq = excluded.cursor_seq,
         cursor_part = excluded.cursor_part, cursor_id = excluded.cursor_id,
         attempts = 0, status = 'ok', last_error = null, updated_at = now();
  update distill_runs set chats = chats + 1, candidates = candidates + jsonb_array_length(v_ids),
                          cost_usd = cost_usd + greatest(coalesce(p_cost, 0), 0)
   where id = p_run;
  return jsonb_build_object('ok', true, 'proposed', v_ids, 'refused', v_errs);
end $$;

-- A chat failed in this run (model error, bad answer). The third failure in a row marks it failed.
create function memohub._distill_fail(p_run uuid, p_chat_ref text, p_error text, p_cost numeric default 0)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare v_attempts int;
begin
  insert into distill_progress as p (chat_ref, attempts, last_error)
  values (p_chat_ref, 1, left(p_error, 300))
  on conflict (chat_ref) do update
     set attempts = p.attempts + 1, last_error = left(p_error, 300), updated_at = now(),
         status = case when p.attempts + 1 >= 3 then 'failed' else p.status end
  returning attempts into v_attempts;
  update distill_runs set cost_usd = cost_usd + greatest(coalesce(p_cost, 0), 0) where id = p_run;
  return jsonb_build_object('ok', true, 'attempts', v_attempts, 'failed', v_attempts >= 3);
end $$;

-- Close a run. A run with p_error is failed; three failed runs in a row pause the distiller.
create function memohub._distill_finish(p_run uuid, p_error text default null)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare v_paused boolean := false;
begin
  update distill_runs set status = case when p_error is null then 'done' else 'failed' end,
                          finished_at = now(), error = left(p_error, 300)
   where id = p_run and status = 'running';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'run_not_running');
  end if;
  if p_error is not null and (select count(*) = 3 and bool_and(status = 'failed') from (
        select status from distill_runs where status <> 'running' order by started_at desc limit 3) r) then
    insert into config (key, value) values ('distill.paused', 'true')
    on conflict (key) do update set value = 'true';
    v_paused := true;
  end if;
  return jsonb_build_object('ok', true, 'paused', v_paused);
end $$;

-- A person clears the pause; with p_retry_failed, failed chats get three more tries.
create function memohub._distill_resume(p_retry_failed boolean default false)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare n int := 0;
begin
  update config set value = 'false' where key = 'distill.paused';
  if p_retry_failed then
    update distill_progress set status = 'ok', attempts = 0, updated_at = now() where status = 'failed';
    get diagnostics n = row_count;
  end if;
  return jsonb_build_object('ok', true, 'retried_chats', n);
end $$;

-- For health(): is it on, is it paused, the last run, what waits for review, which chats failed.
create function memohub._distill_status()
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select jsonb_build_object(
    'enabled', coalesce((select jsonb_array_length(value::jsonb) from config where key = 'distill.allow'), 0) > 0,
    'paused', coalesce((select value from config where key = 'distill.paused'), 'false') = 'true',
    'last_run', (select jsonb_build_object('started_at', started_at, 'status', status, 'model', model,
                                           'chats', chats, 'candidates', candidates, 'cost_usd', cost_usd,
                                           'error', error)
                   from distill_runs order by started_at desc limit 1),
    'cost_30d_usd', (select coalesce(sum(cost_usd), 0) from distill_runs where started_at > now() - interval '30 days'),
    'proposed', (select count(*) from memory_candidates where status = 'proposed'),
    'failed_chats', (select count(*) from distill_progress where status = 'failed'));
$$;

revoke execute on function memohub._distill_allowed(text, text), memohub._distill_allow(jsonb), memohub._distill_begin(text, interval),
  memohub._distill_pending(int, interval), memohub._distill_chat(text, int),
  memohub._distill_record(uuid, text, uuid[], jsonb, numeric), memohub._distill_fail(uuid, text, text, numeric),
  memohub._distill_finish(uuid, text), memohub._distill_resume(boolean), memohub._distill_status() from public;

-- health() gains a 'distill' section; the rest is unchanged from 20261108150000_health.sql.
create or replace function memohub.health(p_days int default 7)
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
    'distill', _distill_status(),
    'database_bytes', pg_database_size(current_database()),
    'database_limit_bytes', _cfg_bigint('database_limit_bytes', 524288000),
    'storage', storage_usage());
$$;
revoke execute on function memohub.health(int) from public;
