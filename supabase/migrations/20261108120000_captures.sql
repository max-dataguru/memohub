-- A1 capture journal: raw user/assistant messages and meeting transcript pieces, captured by a
-- trusted scanner on the owner's computer (scripts/capture.py) and sent in batches. Append-only:
-- rows change only through suppress_chat / forget_chat. Nothing here writes to notes.
--
-- * Routing is decided by the scanner (personal computer -> private DB, work computer -> shared DB, only
--   listed projects and #memo chats); the database does not classify content.
-- * Masking happens twice: in the scanner before sending and again here (_mask_sensitive), so
--   the database stores masked text only.
-- * suppressed_chats is both the #nomemo list and the content-free tombstone of forgotten chats:
--   a trigger skips captures of those chats, so an old backup cannot bring them back.

create table memohub.captures (
  id              uuid primary key default gen_random_uuid(),
  source          text not null check (source in ('claude-code', 'codex', 'meeting', 'claude-ai', 'chatgpt', 'shortcut')),
  device          text not null,
  chat_ref        text not null,                -- globally unique: cc-<uuid>, codex-<uuid>, meeting-<name>
  project_hint    text,                         -- repo / folder the session ran in
  role            text not null check (role in ('user', 'assistant', 'transcript')),
  event_at        timestamptz not null,
  seq             int not null default 0,       -- order within the chat when timestamps tie
  part            int not null default 0,       -- piece of a long message
  idempotency_key text not null unique,
  content         text not null check (length(content) <= 60000),
  content_sha256  text not null,
  masked          text[] not null default '{}', -- kinds masked by the server
  created_at      timestamptz not null default now(),
  fts tsvector generated always as (
    to_tsvector('russian', content) || to_tsvector('simple', content)
  ) stored
);
create index captures_chat_idx   on memohub.captures (chat_ref, event_at, seq, part);
create index captures_event_idx  on memohub.captures (event_at desc);
create index captures_source_idx on memohub.captures (source, device, event_at desc);
create index captures_fts_idx    on memohub.captures using gin (fts);

create table memohub.suppressed_chats (
  chat_ref   text primary key,
  reason     text not null check (reason in ('nomemo', 'forgotten')),
  created_at timestamptz not null default now()
);

create table memohub.capture_sources (
  source        text not null,
  device        text not null,
  cursor        jsonb not null default '{}',   -- scanner's acknowledged positions (for the report)
  last_scan_at  timestamptz,
  last_ok_at    timestamptz,
  last_error    text,
  last_error_at timestamptz,
  items_total   bigint not null default 0,
  primary key (source, device)
);

alter table memohub.captures         enable row level security;
alter table memohub.suppressed_chats enable row level security;
alter table memohub.capture_sources  enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.captures, memohub.suppressed_chats, memohub.capture_sources
      from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.captures, memohub.suppressed_chats, memohub.capture_sources to memohub_backup;
    create policy backup_read on memohub.captures         for select to memohub_backup using (true);
    create policy backup_read on memohub.suppressed_chats for select to memohub_backup using (true);
    create policy backup_read on memohub.capture_sources  for select to memohub_backup using (true);
  end if;
end $$;

-- Captures of suppressed chats are never inserted (also protects restore of an old backup).
create function memohub._skip_suppressed()
returns trigger language plpgsql set search_path = memohub, pg_catalog as $$
begin
  if exists (select 1 from suppressed_chats s where s.chat_ref = new.chat_ref) then
    return null;
  end if;
  return new;
end $$;
create trigger captures_skip_suppressed before insert on memohub.captures
  for each row execute function memohub._skip_suppressed();

-- Replace what sensitive_findings() detects with [masked:<kind>]. Same patterns as the scanner
-- (scripts/capture.py); tests/mask_cases.json keeps both in step.
create function memohub._mask_sensitive(t text)
returns jsonb language plpgsql immutable set search_path = memohub, pg_catalog as $$
declare
  kinds text[] := '{}';
  m     text;
  d     text;
  pat   text;
  before text;
begin
  if t is null or t = '' then
    return jsonb_build_object('text', coalesce(t, ''), 'kinds', '[]'::jsonb);
  end if;

  -- Private key blocks first, before their base64 body is looked at by other patterns.
  before := t;
  t := regexp_replace(t, '-----BEGIN [A-Z ]*PRIVATE KEY-----[A-Za-z0-9+/=\s]*(-----END [A-Z ]*PRIVATE KEY-----)?',
                      '[masked:credential]', 'g');
  if t <> before then kinds := array_append(kinds, 'credential'); end if;

  for m in select distinct (regexp_matches(t, '(?:\d[ -]?){12,18}\d', 'g'))[1] loop
    d := regexp_replace(m, '\D', '', 'g');
    if length(d) between 13 and 19 and _luhn_ok(d) then
      t := replace(t, m, '[masked:card_number]');
      kinds := array_append(kinds, 'card_number');
    end if;
  end loop;

  for m in select distinct (regexp_matches(t, '\m[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}', 'g'))[1] loop
    if _iban_ok(m) then
      t := replace(t, m, '[masked:iban]');
      kinds := array_append(kinds, 'iban');
    end if;
  end loop;

  before := t;
  t := regexp_replace(t, '((?:паспорт|passport)\D{0,30})\d{2} ?\d{2} ?\d{6}', '\1[masked:passport_number]', 'gi');
  if t <> before then kinds := array_append(kinds, 'passport_number'); end if;

  before := t;
  t := regexp_replace(t, '\m\d{3}-\d{3}-\d{3}[ -]\d{2}\M', '[masked:snils]', 'g');
  if t <> before then kinds := array_append(kinds, 'snils'); end if;

  before := t;
  foreach pat in array array[
    'sk-[A-Za-z0-9_-]{20,}',
    'sk_(?:live|test)_[A-Za-z0-9]{16,}',
    'gh[pousr]_[A-Za-z0-9]{30,}', 'github_pat_[A-Za-z0-9_]{30,}',
    'xox[abprs]-[A-Za-z0-9-]{10,}',
    'AKIA[0-9A-Z]{16}',
    'sbp_[a-f0-9]{40}',
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  ] loop
    t := regexp_replace(t, pat, '[masked:credential]', 'g');
  end loop;
  t := regexp_replace(t, '([a-z][a-z0-9+.-]*://)[^\s:/@]+:[^\s@/]+@', '\1[masked:credential]@', 'g');
  t := regexp_replace(t, '((?:password|passwd|pwd|пароль)\s*[:=]\s*)\S{4,}', '\1[masked:credential]', 'gi');
  if t <> before then kinds := array_append(kinds, 'credential'); end if;

  return jsonb_build_object('text', t,
    'kinds', to_jsonb(array(select distinct k from unnest(kinds) k order by k)));
end $$;

-- Suppress a chat: record it and delete what was already captured from it.
create function memohub.suppress_chat(p_chat_ref text, p_reason text default 'nomemo')
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  n int;
begin
  if nullif(trim(p_chat_ref), '') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_chat_ref');
  end if;
  insert into suppressed_chats (chat_ref, reason) values (p_chat_ref, coalesce(p_reason, 'nomemo'))
  on conflict (chat_ref) do update set reason =
    case when suppressed_chats.reason = 'forgotten' then 'forgotten' else excluded.reason end;
  delete from captures where chat_ref = p_chat_ref;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'chat_ref', p_chat_ref, 'deleted', n);
end $$;

-- One call per scanner run: suppressions first, then items, then source status, atomically.
-- p = {device, suppress: [chat_ref], items: [{source, chat_ref, project_hint, role, event_at,
--      seq, part, key, content}], sources: [{source, cursor, scanned_at, error}]}
-- Returns the keys the client may drop from its spool (inserted, already present or suppressed).
create function memohub.capture_batch(p jsonb)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v_device text := nullif(trim(p->>'device'), '');
  it       jsonb;
  s        jsonb;
  v_mask   jsonb;
  v_key    text;
  v_chat   text;
  acked    text[] := '{}';
  rejected jsonb := '[]';
  suppressed_chats jsonb := '[]';
  n_ins int := 0; n_dup int := 0; n_sup int := 0; n_mask int := 0;
  per_source jsonb := '{}';
  r record;
begin
  if v_device is null then
    return jsonb_build_object('ok', false, 'error', 'missing_device');
  end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) > 2000 then
    return jsonb_build_object('ok', false, 'error', 'batch_too_large', 'max_items', 2000);
  end if;

  for v_chat in select jsonb_array_elements_text(coalesce(p->'suppress', '[]')) loop
    if (suppress_chat(v_chat, 'nomemo')->>'ok')::boolean then
      suppressed_chats := suppressed_chats || to_jsonb(v_chat);
    end if;
  end loop;

  for it in select jsonb_array_elements(coalesce(p->'items', '[]')) loop
    v_key  := nullif(it->>'key', '');
    v_chat := nullif(it->>'chat_ref', '');
    if v_key is null or v_chat is null or nullif(it->>'content', '') is null
       or (it->>'source') not in ('claude-code', 'codex', 'meeting', 'claude-ai', 'chatgpt', 'shortcut')
       or (it->>'role') not in ('user', 'assistant', 'transcript') then
      rejected := rejected || jsonb_build_object('key', v_key, 'error', 'invalid_item');
      continue;
    end if;
    if exists (select 1 from suppressed_chats where chat_ref = v_chat) then
      n_sup := n_sup + 1; acked := array_append(acked, v_key); continue;
    end if;
    v_mask := _mask_sensitive(it->>'content');
    if length(v_mask->>'text') > 60000 then
      rejected := rejected || jsonb_build_object('key', v_key, 'error', 'content_too_long', 'max_chars', 60000);
      continue;
    end if;
    insert into captures (source, device, chat_ref, project_hint, role, event_at, seq, part,
                          idempotency_key, content, content_sha256, masked)
    values (it->>'source', v_device, v_chat, nullif(it->>'project_hint', ''), it->>'role',
            coalesce((it->>'event_at')::timestamptz, now()), coalesce((it->>'seq')::int, 0),
            coalesce((it->>'part')::int, 0), v_key, v_mask->>'text',
            encode(sha256(convert_to(v_mask->>'text', 'UTF8')), 'hex'),
            array(select jsonb_array_elements_text(v_mask->'kinds')))
    on conflict (idempotency_key) do nothing;
    if found then
      n_ins := n_ins + 1;
      per_source := jsonb_set(per_source, array[it->>'source'],
                              to_jsonb(coalesce((per_source->>(it->>'source'))::int, 0) + 1));
      if jsonb_array_length(v_mask->'kinds') > 0 then n_mask := n_mask + 1; end if;
    else
      n_dup := n_dup + 1;
    end if;
    acked := array_append(acked, v_key);
  end loop;

  for s in select jsonb_array_elements(coalesce(p->'sources', '[]')) loop
    insert into capture_sources as cs (source, device, cursor, last_scan_at, last_ok_at,
                                       last_error, last_error_at, items_total)
    values (s->>'source', v_device, coalesce(s->'cursor', '{}'),
            coalesce((s->>'scanned_at')::timestamptz, now()),
            case when nullif(s->>'error', '') is null then now() end,
            nullif(s->>'error', ''), case when nullif(s->>'error', '') is not null then now() end,
            coalesce((per_source->>(s->>'source'))::bigint, 0))
    on conflict (source, device) do update set
      cursor        = coalesce(s->'cursor', cs.cursor),
      last_scan_at  = excluded.last_scan_at,
      last_ok_at    = coalesce(excluded.last_ok_at, cs.last_ok_at),
      last_error    = case when excluded.last_error is not null then excluded.last_error else cs.last_error end,
      last_error_at = coalesce(excluded.last_error_at, cs.last_error_at),
      items_total   = cs.items_total + excluded.items_total;
  end loop;

  return jsonb_build_object('ok', true, 'inserted', n_ins, 'duplicates', n_dup,
    'suppressed', n_sup, 'masked', n_mask, 'acked', to_jsonb(acked), 'rejected', rejected,
    'suppressed_chats', suppressed_chats);
end $$;

-- Forget a whole chat: preview first, then delete; the suppression row is the tombstone.
create function memohub.forget_chat(p_chat_ref text, p_confirm boolean default false)
returns jsonb language plpgsql set search_path = memohub, pg_catalog as $$
declare
  v jsonb;
begin
  select jsonb_build_object('chat_ref', p_chat_ref, 'captures', count(*),
           'sources', coalesce(jsonb_agg(distinct source), '[]'),
           'from', min(event_at), 'to', max(event_at))
    into v from captures where chat_ref = p_chat_ref;
  if (v->>'captures')::int = 0 then
    if exists (select 1 from suppressed_chats where chat_ref = p_chat_ref and reason = 'forgotten') then
      return jsonb_build_object('ok', true, 'already_forgotten', true, 'chat_ref', p_chat_ref);
    end if;
    if not coalesce(p_confirm, false) then
      return jsonb_build_object('ok', false, 'error', 'not_found', 'chat_ref', p_chat_ref,
        'hint', 'Nothing captured from this chat. Call with confirm => true to block it anyway.');
    end if;
  end if;
  if not coalesce(p_confirm, false) then
    return v || jsonb_build_object('ok', false, 'error', 'confirm_required',
      'hint', 'Show this to the user; after an explicit yes call forget_chat(chat_ref, true).');
  end if;
  perform suppress_chat(p_chat_ref, 'forgotten');
  return jsonb_build_object('ok', true, 'forgotten', p_chat_ref, 'captures_deleted', (v->>'captures')::int,
    'hint', 'Backups keep it until they expire (30 days).');
end $$;

-- Full-text search over the journal (raw, unconfirmed). Separate from notes search on purpose.
create function memohub.search_captures(
  q text, p_source text default null, p_since date default null,
  p_chat_ref text default null, p_limit int default 20)
returns jsonb language plpgsql stable set search_path = memohub, pg_catalog as $$
declare
  v_q tsquery;
  v_items jsonb;
  v_total int;
begin
  if nullif(trim(q), '') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_query');
  end if;
  v_q := websearch_to_tsquery('russian', q) || websearch_to_tsquery('simple', q);
  select count(*) into v_total from captures c
   where c.fts @@ v_q
     and (p_source is null or c.source = p_source)
     and (p_since is null or c.event_at >= p_since)
     and (p_chat_ref is null or c.chat_ref = p_chat_ref);
  select coalesce(jsonb_agg(x order by x.rank desc, x.event_at desc), '[]') into v_items from (
    select c.id, c.chat_ref, c.source, c.device, c.project_hint, c.role, c.event_at,
           ts_rank(c.fts, v_q) as rank,
           ts_headline('russian', c.content, v_q, 'MaxWords=40, MinWords=15, MaxFragments=2') as snippet
      from captures c
     where c.fts @@ v_q
       and (p_source is null or c.source = p_source)
       and (p_since is null or c.event_at >= p_since)
       and (p_chat_ref is null or c.chat_ref = p_chat_ref)
     order by ts_rank(c.fts, v_q) desc, c.event_at desc
     limit greatest(1, least(coalesce(p_limit, 20), 100))) x;
  return jsonb_build_object('ok', true, 'total', v_total, 'returned', jsonb_array_length(v_items),
    'items', v_items, 'note', 'Raw journal, not confirmed notes. captures_by_chat(chat_ref) shows the context.');
end $$;

-- A chat from the journal in order, page by page.
create function memohub.captures_by_chat(p_chat_ref text, p_offset int default 0, p_limit int default 50)
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select jsonb_build_object(
    'chat_ref', p_chat_ref,
    'total', (select count(*) from captures where chat_ref = p_chat_ref),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('role', c.role, 'event_at', c.event_at, 'part', c.part,
                                          'content', c.content) order by c.event_at, c.seq, c.part)
        from (select * from captures where chat_ref = p_chat_ref
               order by event_at, seq, part offset greatest(p_offset, 0)
               limit greatest(1, least(p_limit, 200))) c), '[]'));
$$;

-- Completeness and size, for the A3 report.
create function memohub.capture_status()
returns jsonb language sql stable set search_path = memohub, pg_catalog as $$
  select jsonb_build_object(
    'sources', coalesce((select jsonb_agg(jsonb_build_object(
        'source', s.source, 'device', s.device, 'last_scan_at', s.last_scan_at,
        'last_ok_at', s.last_ok_at, 'last_error', s.last_error, 'last_error_at', s.last_error_at,
        'items_total', s.items_total,
        'last_capture_at', (select max(c.event_at) from captures c where c.source = s.source and c.device = s.device))
        order by s.source, s.device) from capture_sources s), '[]'),
    'captures', (select count(*) from captures),
    'chats', (select count(distinct chat_ref) from captures),
    'suppressed', (select count(*) from suppressed_chats),
    'journal_bytes', pg_total_relation_size('memohub.captures'),
    'database_bytes', pg_database_size(current_database()));
$$;

revoke execute on function memohub._skip_suppressed(), memohub._mask_sensitive(text),
  memohub.suppress_chat(text, text), memohub.capture_batch(jsonb),
  memohub.forget_chat(text, boolean), memohub.search_captures(text, text, date, text, int),
  memohub.captures_by_chat(text, int, int), memohub.capture_status() from public;
