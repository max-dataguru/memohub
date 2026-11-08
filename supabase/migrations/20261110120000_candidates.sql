-- 0.5 "human decisions are changed only by a human", held by the database. What automation
-- concludes from the journal is a candidate in its own table, never a note: notes holds only what
-- a human confirmed (tomemo, or approving a candidate). Design: docs/ROADMAP.md, 0.5.
--
-- * A candidate lives in the database that holds its raw captures, so its source links and
--   forget_chat never cross databases. A work candidate found in the private database is saved
--   to the shared one by the client and marked exported here (content wiped).
-- * Only memohub._propose() creates candidates. It is owner-only and is called by the distiller's
--   response parser (A4) with the capture ids that were actually sent; no client can call it.
-- * Approval goes through save() with all its checks (similar_exists, same_chat, contradictions);
--   an amend whose target changed after the proposal is returned to the human (target_changed).
-- * A rejected candidate keeps only its title and source hash: the same set of captures is never
--   proposed again.
-- * forget(note) removes candidates that target or produced the note (FK cascade); forget_chat
--   and #nomemo remove candidates built on that chat. One advisory lock per chat_ref serialises
--   suppression with capture inserts and proposals, so nothing slips past a concurrent forget.

-- Text masked by the journal ("пароль: [masked:credential]", "postgres://[masked:credential]@h")
-- is no longer reported as a secret, so an approved candidate or a note quoting the journal saves.
create or replace function memohub.sensitive_findings(t text)
returns text[]
language plpgsql immutable
set search_path = memohub, pg_catalog
as $$
declare
  kinds text[] := '{}';
  m     text;
  pat   text;
begin
  if t is null or t = '' then
    return kinds;
  end if;

  for m in select (regexp_matches(t, '(?:\d[ -]?){12,18}\d', 'g'))[1] loop
    if _is_card_number(m) then
      kinds := array_append(kinds, 'card_number');
      exit;
    end if;
  end loop;

  for m in select (regexp_matches(t, '\m[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}', 'g'))[1] loop
    if _iban_ok(m) then
      kinds := array_append(kinds, 'iban');
      exit;
    end if;
  end loop;

  if t ~* '(паспорт|passport)\D{0,30}\d{2} ?\d{2} ?\d{6}' then
    kinds := array_append(kinds, 'passport_number');
  end if;

  if t ~ '\m\d{3}-\d{3}-\d{3}[ -]\d{2}\M' then
    kinds := array_append(kinds, 'snils');
  end if;

  foreach pat in array array[
    'sk-[A-Za-z0-9_-]{20,}',                              -- OpenAI / Anthropic style keys
    'sk_(live|test)_[A-Za-z0-9]{16,}',                    -- Stripe
    'gh[pousr]_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{30,}',
    'xox[abprs]-[A-Za-z0-9-]{10,}',                       -- Slack
    'AKIA[0-9A-Z]{16}',                                   -- AWS access key
    'sbp_[a-f0-9]{40}',                                   -- Supabase access token
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',  -- JWT
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '[a-z][a-z0-9+.-]*://(?!\[masked:)[^\s:/@]+:[^\s@/]+@'  -- URL with user:password
  ] loop
    if t ~ pat then
      kinds := array_append(kinds, 'credential');
      exit;
    end if;
  end loop;
  if t ~* '(password|passwd|pwd|пароль)\s*[:=]\s*(?!\[masked:)\S{4,}' then
    kinds := array_append(kinds, 'credential');
  end if;

  return array(select distinct k from unnest(kinds) k order by k);
end;
$$;

alter table memohub.notes drop constraint notes_source_check;
alter table memohub.notes add constraint notes_source_check
  check (source in ('claude', 'claude-code', 'chatgpt', 'codex', 'manual', 'distiller'));

create table memohub.memory_candidates (
  id              uuid primary key default gen_random_uuid(),
  kind            text not null check (kind in ('new', 'amend')),
  status          text not null default 'proposed' check (status in ('proposed', 'accepted', 'rejected')),
  title           text not null,
  payload         jsonb not null,               -- save() input; '{}' once accepted or rejected
  confidence      numeric check (confidence between 0 and 1),
  target_note_id  uuid references memohub.notes(id) on delete cascade,
  target_updated_at timestamptz,
  source_hash     text not null unique,         -- sha256 over sorted capture id:content_sha256
  model           text,
  run_id          uuid,
  created_at      timestamptz not null default now(),
  reviewed_at     timestamptz,
  reject_reason   text,
  result_note_id  uuid references memohub.notes(id) on delete cascade,
  result_db       text check (result_db in ('this', 'shared')),
  check ((kind = 'amend') = (target_note_id is not null))
);
create index memory_candidates_status_idx on memohub.memory_candidates (status, created_at);
create index memory_candidates_run_idx on memohub.memory_candidates (run_id);

create table memohub.candidate_sources (
  candidate_id uuid not null references memohub.memory_candidates(id) on delete cascade,
  capture_id   uuid not null references memohub.captures(id) on delete cascade,
  primary key (candidate_id, capture_id)
);
create index candidate_sources_capture_idx on memohub.candidate_sources (capture_id);

alter table memohub.memory_candidates enable row level security;
alter table memohub.candidate_sources enable row level security;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.memory_candidates, memohub.candidate_sources from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.memory_candidates, memohub.candidate_sources to memohub_backup;
    create policy backup_read on memohub.memory_candidates for select to memohub_backup using (true);
    create policy backup_read on memohub.candidate_sources for select to memohub_backup using (true);
  end if;
end $$;

-- One lock key per chat: shared for inserting captures and proposing, exclusive for suppressing.
create function memohub._chat_lock_key(p_chat_ref text)
returns bigint language sql immutable parallel safe
set search_path = pg_catalog as $$
  select hashtextextended('memohub.chat:' || coalesce(p_chat_ref, ''), 0)
$$;

create or replace function memohub._skip_suppressed()
returns trigger language plpgsql set search_path = memohub, pg_catalog as $$
begin
  perform pg_advisory_xact_lock_shared(_chat_lock_key(new.chat_ref));
  if exists (select 1 from suppressed_chats s where s.chat_ref = new.chat_ref) then
    return null;
  end if;
  return new;
end $$;

-- Suppress a chat: record it, then delete what was captured from it and the candidates built on it.
create or replace function memohub.suppress_chat(p_chat_ref text, p_reason text default 'nomemo')
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  n int;
  n_cand int;
begin
  if nullif(trim(p_chat_ref), '') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_chat_ref');
  end if;
  perform pg_advisory_xact_lock(_chat_lock_key(p_chat_ref));
  insert into suppressed_chats (chat_ref, reason) values (p_chat_ref, coalesce(p_reason, 'nomemo'))
  on conflict (chat_ref) do update set reason =
    case when suppressed_chats.reason = 'forgotten' then 'forgotten' else excluded.reason end;
  -- Candidates in any status: their text came from this chat. Accepted notes stay (a human
  -- confirmed them); the FK only drops the link.
  delete from memory_candidates m
   where exists (select 1 from candidate_sources cs join captures c on c.id = cs.capture_id
                  where cs.candidate_id = m.id and c.chat_ref = p_chat_ref)
     and m.status <> 'accepted';
  get diagnostics n_cand = row_count;
  delete from captures where chat_ref = p_chat_ref;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'chat_ref', p_chat_ref, 'deleted', n, 'candidates_deleted', n_cand);
end $$;

-- Mask every string in a JSON value: strings, array elements and object values, at any depth.
create function memohub._mask_json(v jsonb)
returns jsonb language plpgsql immutable
set search_path = memohub, pg_catalog as $$
begin
  return case jsonb_typeof(v)
    when 'string' then to_jsonb(_mask_sensitive(v #>> '{}')->>'text')
    when 'array' then coalesce((select jsonb_agg(_mask_json(e) order by o)
                                  from jsonb_array_elements(v) with ordinality t(e, o)), '[]'::jsonb)
    when 'object' then coalesce((select jsonb_object_agg(k, _mask_json(e))
                                   from jsonb_each(v) t(k, e)), '{}'::jsonb)
    else v end;
end $$;

-- Create one candidate. Owner-only: called by the distiller's response parser (A4).
-- p = {kind, target_note_id?, confidence?, model?, payload: {space, project, title, body_md,
--      decisions, open_questions, entities, tags, type}, capture_ids: [uuid]}
-- p_sent: the capture ids that were sent in this run; a candidate may cite only those.
create function memohub._propose(p_run uuid, p jsonb, p_sent uuid[],
                                 p_max_per_run int default 10)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v_kind    text := coalesce(nullif(p->>'kind', ''), 'new');
  v_payload jsonb := coalesce(p->'payload', '{}'::jsonb);
  v_ids     uuid[];
  v_hash    text;
  v_target  notes;
  v_chat    text;
  v_id      uuid;
  v_key     text;
begin
  if v_kind not in ('new', 'amend') then
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;
  if jsonb_typeof(v_payload) <> 'object' or nullif(trim(v_payload->>'title'), '') is null
     or nullif(trim(v_payload->>'space'), '') is null then
    return jsonb_build_object('ok', false, 'error', 'bad_payload');
  end if;
  -- Only fields save() takes: nothing else is stored, so nothing unmasked can hide in the payload.
  if exists (select 1 from jsonb_object_keys(v_payload) k
              where k not in ('space', 'project', 'type', 'title', 'body_md', 'decisions',
                              'open_questions', 'tags', 'entities', 'relations')) then
    return jsonb_build_object('ok', false, 'error', 'unknown_fields',
      'got', (select jsonb_agg(k) from jsonb_object_keys(v_payload) k
               where k not in ('space', 'project', 'type', 'title', 'body_md', 'decisions',
                               'open_questions', 'tags', 'entities', 'relations')));
  end if;
  if length(coalesce(v_payload->>'body_md', '')) > 8000 or length(v_payload->>'title') > 300 then
    return jsonb_build_object('ok', false, 'error', 'too_long');
  end if;
  begin
    select array_agg(distinct x::uuid order by x::uuid) into v_ids
      from jsonb_array_elements_text(coalesce(p->'capture_ids', '[]'::jsonb)) x;
  exception when invalid_text_representation then
    return jsonb_build_object('ok', false, 'error', 'bad_capture_ids');
  end;
  if v_ids is null then
    return jsonb_build_object('ok', false, 'error', 'no_sources');
  end if;
  if not v_ids <@ coalesce(p_sent, '{}') then
    return jsonb_build_object('ok', false, 'error', 'source_not_sent');
  end if;
  -- One proposal per run at a time, so the per-run limit holds under concurrent calls.
  if p_run is not null then
    perform pg_advisory_xact_lock(hashtextextended('memohub.run:' || p_run::text, 0));
  end if;
  if p_run is not null and (select count(*) from memory_candidates where run_id = p_run) >= p_max_per_run then
    return jsonb_build_object('ok', false, 'error', 'run_limit', 'max', p_max_per_run);
  end if;

  -- Lock every source chat (shared), then make sure none of it was suppressed or forgotten.
  for v_chat in select distinct chat_ref from captures where id = any (v_ids) order by 1 loop
    perform pg_advisory_xact_lock_shared(_chat_lock_key(v_chat));
  end loop;
  if (select count(*) from captures c where c.id = any (v_ids)
        and not exists (select 1 from suppressed_chats s where s.chat_ref = c.chat_ref)) <> cardinality(v_ids) then
    return jsonb_build_object('ok', false, 'error', 'source_gone');
  end if;

  select encode(sha256(convert_to(string_agg(c.id::text || ':' || c.content_sha256, ',' order by c.id), 'UTF8')), 'hex')
    into v_hash from captures c where c.id = any (v_ids);
  if exists (select 1 from memory_candidates where source_hash = v_hash) then
    return jsonb_build_object('ok', false, 'error', 'already_proposed');
  end if;

  if v_kind = 'amend' then
    if coalesce(p->>'target_note_id', '') !~ '^[0-9a-f-]{36}$' then
      return jsonb_build_object('ok', false, 'error', 'bad_target');
    end if;
    select * into v_target from notes where id = nullif(p->>'target_note_id', '')::uuid;
    if not found or v_target.status <> 'active' then
      return jsonb_build_object('ok', false, 'error', 'bad_target');
    end if;
  end if;

  -- Second masking pass over every text field (the journal is masked already).
  for v_key in select k from jsonb_object_keys(v_payload) k loop
    v_payload := jsonb_set(v_payload, array[v_key], _mask_json(v_payload->v_key));
  end loop;

  insert into memory_candidates (kind, title, payload, confidence, target_note_id, target_updated_at,
                                 source_hash, model, run_id)
  values (v_kind, trim(v_payload->>'title'), v_payload,
          least(greatest(nullif(p->>'confidence', '')::numeric, 0), 1),
          v_target.id, v_target.updated_at, v_hash, nullif(p->>'model', ''), p_run)
  returning id into v_id;
  insert into candidate_sources (candidate_id, capture_id) select v_id, unnest(v_ids);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Candidates for review, oldest first, with where they came from and whether an amend's target
-- changed since.
create function memohub.candidates(p_status text default 'proposed', p_limit int default 20)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select jsonb_build_object(
    'total', (select count(*) from memory_candidates where status = coalesce(p_status, 'proposed')),
    'items', coalesce(jsonb_agg(x order by x->>'created_at'), '[]'::jsonb),
    'hint', 'Show each to the user. approve_candidate(id, edits) saves it as a note through save(); '
            || 'reject_candidate(id, reason) drops it. A work candidate in the private database: save it '
            || 'in the shared one, then mark_candidate_exported(id).')
  from (
    select jsonb_build_object(
      'id', m.id, 'kind', m.kind, 'title', m.title, 'payload', m.payload, 'confidence', m.confidence,
      'created_at', m.created_at, 'status', m.status, 'reject_reason', m.reject_reason,
      'target', case when m.target_note_id is not null then jsonb_build_object(
          'id', t.id, 'title', t.title, 'status', t.status,
          'target_changed', t.status <> 'active' or t.updated_at is distinct from m.target_updated_at) end,
      'sources', (select jsonb_build_object('captures', count(*), 'chats', jsonb_agg(distinct c.chat_ref),
                                            'from', min(c.event_at), 'to', max(c.event_at))
                    from candidate_sources cs join captures c on c.id = cs.capture_id
                   where cs.candidate_id = m.id)) as x
      from memory_candidates m left join notes t on t.id = m.target_note_id
     where m.status = coalesce(p_status, 'proposed')
     order by m.created_at
     limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ) s
$$;

-- Approve: the candidate (with the user's edits) goes through save(). Errors of save() come back
-- unchanged and the candidate stays proposed.
create function memohub.approve_candidate(p_id uuid, p_edits jsonb default null)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  m      memory_candidates;
  v_t    notes;
  v_p    jsonb;
  r      jsonb;
begin
  select * into m from memory_candidates where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if m.status <> 'proposed' then
    return jsonb_build_object('ok', false, 'error', 'already_reviewed', 'status', m.status);
  end if;
  if p_edits is not null and jsonb_typeof(p_edits) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'edits_not_object');
  end if;
  v_p := m.payload || coalesce(p_edits, '{}'::jsonb) - 'supersedes' - 'source' - 'device' - 'chat_ref';
  if m.kind = 'amend' then
    select * into v_t from notes where id = m.target_note_id for update;
    if v_t.status <> 'active' or v_t.updated_at is distinct from m.target_updated_at then
      return jsonb_build_object('ok', false, 'error', 'target_changed',
        'target', jsonb_build_object('id', v_t.id, 'title', v_t.title, 'status', v_t.status),
        'hint', 'The note this candidate amends changed after the proposal. Show both to the user; '
                || 'reject this candidate or save its content yourself.');
    end if;
    v_p := v_p || jsonb_build_object('supersedes', m.target_note_id);
  end if;
  r := save(v_p || jsonb_build_object('source', 'distiller'));
  if not coalesce((r->>'ok')::boolean, false) then
    return r || jsonb_build_object('candidate_id', p_id);
  end if;
  update memory_candidates set status = 'accepted', reviewed_at = now(), payload = '{}'::jsonb,
         result_note_id = (r->>'id')::uuid, result_db = 'this'
   where id = p_id;
  return r || jsonb_build_object('candidate_id', p_id);
end $$;

create function memohub.reject_candidate(p_id uuid, p_reason text default null)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare n int;
begin
  update memory_candidates set status = 'rejected', reviewed_at = now(), payload = '{}'::jsonb,
         reject_reason = left(nullif(trim(p_reason), ''), 500)
   where id = p_id and status = 'proposed';
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('ok', false, 'error',
      case when exists (select 1 from memory_candidates where id = p_id) then 'already_reviewed' else 'not_found' end);
  end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', 'rejected');
end $$;

-- The client saved this candidate in the shared database itself: keep only the trace here.
create function memohub.mark_candidate_exported(p_id uuid)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare n int;
begin
  update memory_candidates set status = 'accepted', reviewed_at = now(), payload = '{}'::jsonb,
         result_db = 'shared'
   where id = p_id and status = 'proposed';
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('ok', false, 'error',
      case when exists (select 1 from memory_candidates where id = p_id) then 'already_reviewed' else 'not_found' end);
  end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', 'accepted', 'result_db', 'shared');
end $$;

revoke execute on function memohub._chat_lock_key(text), memohub._mask_json(jsonb),
  memohub._propose(uuid, jsonb, uuid[], int), memohub.candidates(text, int),
  memohub.approve_candidate(uuid, jsonb), memohub.reject_candidate(uuid, text),
  memohub.mark_candidate_exported(uuid) from public;

-- Client API: review is a human decision in chat, like save().
create function memohub_api.candidates(p_status text default 'proposed', p_limit int default 20)
returns jsonb language plpgsql stable security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.candidates(p_status, p_limit); end $$;

create function memohub_api.approve_candidate(p_id uuid, p_edits jsonb default null)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.approve_candidate(p_id, p_edits); end $$;

create function memohub_api.reject_candidate(p_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.reject_candidate(p_id, p_reason); end $$;

create function memohub_api.mark_candidate_exported(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = memohub, pg_catalog as $$
begin perform memohub._require_member(); return memohub.mark_candidate_exported(p_id); end $$;

revoke execute on function memohub_api.candidates(text, int), memohub_api.approve_candidate(uuid, jsonb),
  memohub_api.reject_candidate(uuid, text), memohub_api.mark_candidate_exported(uuid) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function memohub_api.candidates(text, int), memohub_api.approve_candidate(uuid, jsonb),
      memohub_api.reject_candidate(uuid, text), memohub_api.mark_candidate_exported(uuid)
      from anon, service_role;
  end if;
end $$;
grant execute on function memohub_api.candidates(text, int), memohub_api.approve_candidate(uuid, jsonb),
  memohub_api.reject_candidate(uuid, text), memohub_api.mark_candidate_exported(uuid) to authenticated;
