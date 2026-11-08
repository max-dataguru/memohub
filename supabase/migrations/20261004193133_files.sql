-- Files attached to notes.
-- Personal documents live in a private Storage bucket `files` of the same project as the note
-- (so medical / legal files stay in memohub-private); company documents are stored as a link.
-- Uploads are checked against the storage quota first: over the limit is refused, close to it
-- is reported as a warning.

-- Bucket ------------------------------------------------------------------------

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('files', 'files', false, 52428800)
    on conflict (id) do nothing;
  end if;
end $$;

-- Table -------------------------------------------------------------------------

create table memohub.files (
  id             uuid primary key default gen_random_uuid(),
  note_id        uuid not null references memohub.notes (id),
  kind           text not null check (kind in ('supabase', 'url')),
  path           text,                 -- object name in bucket `files` (kind = supabase)
  url            text,                 -- external link (kind = url), e.g. a company document
  name           text not null,
  mime           text,
  size_bytes     bigint,
  sha256         text,
  summary        text not null default '',
  extracted_text text not null default '',
  source         text,
  device         text,
  created_at     timestamptz not null default now(),
  check ((kind = 'supabase' and path is not null) or (kind = 'url' and url is not null)),
  fts tsvector generated always as (
    setweight(to_tsvector('russian', name), 'A') ||
    setweight(to_tsvector('russian', summary), 'B') ||
    setweight(to_tsvector('russian', extracted_text), 'C')
  ) stored
);

create index files_note_idx   on memohub.files (note_id);
create index files_sha256_idx on memohub.files (sha256);
create index files_fts_idx    on memohub.files using gin (fts);
create unique index files_path_uidx on memohub.files (path) where path is not null;

alter table memohub.files enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on memohub.files from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'memohub_backup') then
    grant select on memohub.files to memohub_backup;
    create policy backup_read on memohub.files for select to memohub_backup using (true);
  end if;
end $$;

-- Quota -------------------------------------------------------------------------
-- Limits come from config (free tier defaults): storage_limit_bytes = 1 GB per project,
-- storage_warn_pct = 80, max_file_bytes = 50 MB.

create or replace function memohub._cfg_bigint(p_key text, p_default bigint)
returns bigint
language sql stable
set search_path = memohub, pg_catalog
as $$ select coalesce((select value::bigint from config where key = p_key), p_default) $$;

create or replace function memohub.storage_usage()
returns jsonb
language plpgsql stable
set search_path = memohub, pg_catalog
as $$
declare
  v_used  bigint := 0;
  v_count int := 0;
  v_limit bigint := _cfg_bigint('storage_limit_bytes', 1073741824);
  v_warn  int := _cfg_bigint('storage_warn_pct', 80);
  v_pct   numeric;
begin
  -- Dynamic SQL: the storage schema exists on Supabase but not in plain Postgres tests.
  if to_regclass('storage.objects') is not null then
    execute $q$ select coalesce(sum((metadata->>'size')::bigint), 0), count(*)
                  from storage.objects where bucket_id = 'files' $q$
      into v_used, v_count;
  end if;
  v_pct := round(100.0 * v_used / v_limit, 1);
  return jsonb_build_object(
    'used_bytes', v_used, 'limit_bytes', v_limit, 'used_pct', v_pct, 'files', v_count,
    'warn_pct', v_warn, 'warn', v_pct >= v_warn,
    'human', pg_size_pretty(v_used) || ' из ' || pg_size_pretty(v_limit) || ' (' || v_pct || '%)'
  );
end;
$$;

create or replace function memohub.check_upload(p_size_bytes bigint, p_sha256 text default null)
returns jsonb
language plpgsql stable
set search_path = memohub, pg_catalog
as $$
declare
  v_usage jsonb := storage_usage();
  v_max   bigint := _cfg_bigint('max_file_bytes', 52428800);
  v_after bigint;
  v_pct   numeric;
  v_dup   jsonb;
begin
  if p_size_bytes is null or p_size_bytes <= 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_size');
  end if;

  if p_sha256 is not null then
    select jsonb_build_object('file_id', f.id, 'note_id', f.note_id, 'name', f.name, 'path', f.path)
      into v_dup
      from files f where f.sha256 = lower(p_sha256) limit 1;
    if v_dup is not null then
      return jsonb_build_object('ok', true, 'duplicate', v_dup, 'usage', v_usage,
        'hint', 'This exact file is already stored. Link the existing file instead of uploading again.');
    end if;
  end if;

  if p_size_bytes > v_max then
    return jsonb_build_object('ok', false, 'error', 'file_too_large',
      'size', pg_size_pretty(p_size_bytes), 'max', pg_size_pretty(v_max),
      'hint', 'Too large for Storage on this plan. Keep the file elsewhere and save a link (kind = url).');
  end if;

  v_after := (v_usage->>'used_bytes')::bigint + p_size_bytes;
  v_pct := round(100.0 * v_after / (v_usage->>'limit_bytes')::bigint, 1);

  if v_after > (v_usage->>'limit_bytes')::bigint then
    return jsonb_build_object('ok', false, 'error', 'quota_exceeded', 'usage', v_usage,
      'after_pct', v_pct,
      'hint', 'Not enough storage. Tell the user: free space by removing old files, '
              || 'keep this file elsewhere and save a link, or upgrade the Supabase plan.');
  end if;

  return jsonb_build_object('ok', true, 'usage', v_usage, 'after_pct', v_pct,
    'warn', v_pct >= (v_usage->>'warn_pct')::int,
    'message', case when v_pct >= (v_usage->>'warn_pct')::int
      then 'После загрузки хранилище будет заполнено на ' || v_pct || '% ('
           || pg_size_pretty(v_after) || ' из ' || pg_size_pretty((v_usage->>'limit_bytes')::bigint)
           || '). Предупреди пользователя.'
      end);
end;
$$;

-- Attach ------------------------------------------------------------------------

create or replace function memohub.attach_file(p jsonb)
returns jsonb
language plpgsql
set search_path = memohub, pg_catalog
as $$
declare
  v_note  uuid := nullif(p->>'note_id', '')::uuid;
  v_kind  text := coalesce(nullif(p->>'kind', ''), case when p ? 'url' then 'url' else 'supabase' end);
  v_path  text := nullif(trim(p->>'path'), '');
  v_url   text := nullif(trim(p->>'url'), '');
  v_name  text;
  v_size  bigint := nullif(p->>'size_bytes', '')::bigint;
  v_mime  text := nullif(p->>'mime', '');
  v_text  text := coalesce(p->>'extracted_text', '');
  v_cut   boolean := false;
  v_meta  jsonb;
  v_kinds text[];
  v_id    uuid;
begin
  if v_note is null or not exists (select 1 from notes where id = v_note) then
    return jsonb_build_object('ok', false, 'error', 'unknown_note',
      'hint', 'Save the note first (memohub.save) and pass its id as note_id.');
  end if;

  if v_kind = 'supabase' then
    if v_path is null then
      return jsonb_build_object('ok', false, 'error', 'missing_path');
    end if;
    if to_regclass('storage.objects') is not null then
      execute $q$ select metadata from storage.objects where bucket_id = 'files' and name = $1 $q$
        into v_meta using v_path;
      if v_meta is null then
        return jsonb_build_object('ok', false, 'error', 'object_not_found', 'path', v_path,
          'hint', 'Upload the file to bucket "files" first (CLI: supabase storage cp <file> ss:///files/<path>).');
      end if;
      v_size := coalesce((v_meta->>'size')::bigint, v_size);
      v_mime := coalesce(v_meta->>'mimetype', v_mime);
    end if;
  elsif v_kind = 'url' then
    if v_url is null or v_url !~* '^https?://' then
      return jsonb_build_object('ok', false, 'error', 'bad_url');
    end if;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind', 'allowed', jsonb_build_array('supabase', 'url'));
  end if;

  v_name := coalesce(nullif(trim(p->>'name'), ''),
                     regexp_replace(coalesce(v_path, v_url), '^.*/', ''));

  v_kinds := sensitive_findings(concat_ws(' ', v_name, p->>'summary', v_text));
  if cardinality(v_kinds) > 0 then
    return jsonb_build_object('ok', false, 'error', 'sensitive_data', 'kinds', to_jsonb(v_kinds),
      'hint', 'The name, summary or extracted text contains these values. Generalize the summary; '
              || 'drop extracted_text if the document itself is an ID or a statement. '
              || 'The file in storage is not affected. Values are not echoed back.');
  end if;

  if length(v_text) > 200000 then
    v_text := left(v_text, 200000);
    v_cut := true;
  end if;

  insert into files (note_id, kind, path, url, name, mime, size_bytes, sha256, summary,
                     extracted_text, source, device)
  values (v_note, v_kind, v_path, v_url, v_name, v_mime, v_size, lower(nullif(p->>'sha256', '')),
          coalesce(p->>'summary', ''), v_text, nullif(p->>'source', ''), nullif(p->>'device', ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'file_id', v_id, 'note_id', v_note, 'name', v_name,
                            'text_truncated', v_cut, 'usage', storage_usage(), 'tier', tier());
end;
$$;

-- Read --------------------------------------------------------------------------

create or replace function memohub.get(p_id uuid)
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select coalesce(
    (select (to_jsonb(n) - 'fts') || jsonb_build_object('files', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', f.id, 'kind', f.kind, 'name', f.name, 'path', f.path, 'url', f.url,
                       'mime', f.mime, 'size', pg_size_pretty(f.size_bytes), 'summary', f.summary,
                       'has_text', f.extracted_text <> '')
                     order by f.created_at)
                from files f where f.note_id = n.id), '[]'::jsonb))
       from notes n where n.id = p_id),
    jsonb_build_object('ok', false, 'error', 'not_found', 'id', p_id)
  );
$$;

-- Extracted text in pages, so a long PDF does not land in the context at once.
create or replace function memohub.get_file(p_id uuid, p_offset int default 0)
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select coalesce(
    (select (to_jsonb(f) - 'fts' - 'extracted_text') || jsonb_build_object(
              'text', substr(f.extracted_text, greatest(p_offset, 0) + 1, 20000),
              'text_offset', greatest(p_offset, 0),
              'text_total', length(f.extracted_text),
              'text_truncated', length(f.extracted_text) > greatest(p_offset, 0) + 20000,
              'hint', 'Next page: memohub.get_file(id, text_offset + 20000)')
       from files f where f.id = p_id),
    jsonb_build_object('ok', false, 'error', 'not_found', 'id', p_id)
  );
$$;

-- Search: a note also matches through its files (name, summary, extracted text).
create or replace function memohub.search(
  q                    text    default null,
  p_space              text    default null,
  p_project            text    default null,
  p_since              date    default null,
  p_limit              int     default 8,
  p_include_superseded boolean default false
)
returns jsonb
language plpgsql stable
set search_path = memohub, pg_catalog
as $$
declare
  v_lim   int := least(greatest(coalesce(p_limit, 8), 1), 25);
  v_text  text := nullif(trim(q), '');
  v_q     tsquery;
  v_mode  text := 'recent';
  v_total int;
  v_items jsonb;
begin
  if v_text is not null then
    v_q := websearch_to_tsquery('russian', v_text);
    v_mode := 'fulltext';
  end if;

  select count(*) into v_total
    from notes n
   where (v_q is null or n.fts @@ v_q
          or exists (select 1 from files f where f.note_id = n.id and f.fts @@ v_q))
     and (p_space is null or n.space = p_space)
     and (p_project is null or n.project = lower(p_project))
     and (p_since is null or n.created_at >= p_since)
     and (p_include_superseded or n.status = 'active');

  -- Any term: OR over the stemmed lexemes of the query (stop words already dropped).
  if v_total = 0 and v_text is not null then
    select string_agg(quote_literal(lexeme), ' | ')::tsquery into v_q
      from unnest(tsvector_to_array(to_tsvector('russian', v_text))) as lexeme;
    if v_q is not null then
      v_mode := 'fulltext_any';
      select count(*) into v_total
        from notes n
       where (n.fts @@ v_q
              or exists (select 1 from files f where f.note_id = n.id and f.fts @@ v_q))
         and (p_space is null or n.space = p_space)
         and (p_project is null or n.project = lower(p_project))
         and (p_since is null or n.created_at >= p_since)
         and (p_include_superseded or n.status = 'active');
    end if;
  end if;

  -- Names, codes and partial words the stemmer misses: fall back to substring.
  if v_total = 0 and v_text is not null then
    v_mode := 'substring';
    select count(*) into v_total
      from notes n
     where (n.title ilike '%' || v_text || '%' or n.body_md ilike '%' || v_text || '%'
            or exists (select 1 from files f where f.note_id = n.id
                                              and f.name ilike '%' || v_text || '%'))
       and (p_space is null or n.space = p_space)
       and (p_project is null or n.project = lower(p_project))
       and (p_since is null or n.created_at >= p_since)
       and (p_include_superseded or n.status = 'active');
  end if;

  select coalesce(jsonb_agg(item order by ord), '[]'::jsonb) into v_items
  from (
    select row_number() over () as ord,
           jsonb_build_object(
             'id', n.id, 'space', n.space, 'project', n.project, 'type', n.type,
             'title', n.title, 'status', n.status, 'source', n.source,
             'date', to_char(n.created_at, 'YYYY-MM-DD'),
             'files', (select count(*) from files f where f.note_id = n.id),
             'snippet', case
               when v_mode in ('fulltext', 'fulltext_any') and n.fts @@ v_q
                 then ts_headline('russian', n.body_md, v_q,
                                  'MaxWords=35, MinWords=12, MaxFragments=2')
               when v_mode in ('fulltext', 'fulltext_any')
                 then (select 'файл «' || f.name || '»: '
                              || ts_headline('russian', f.summary || ' ' || left(f.extracted_text, 20000),
                                             v_q, 'MaxWords=35, MinWords=12, MaxFragments=2')
                         from files f where f.note_id = n.id and f.fts @@ v_q
                        order by ts_rank(f.fts, v_q) desc limit 1)
               else left(n.body_md, 240) end
           ) as item
      from notes n
     where (case
              when v_mode in ('fulltext', 'fulltext_any')
                then n.fts @@ v_q
                     or exists (select 1 from files f where f.note_id = n.id and f.fts @@ v_q)
              when v_mode = 'substring'
                then n.title ilike '%' || v_text || '%' or n.body_md ilike '%' || v_text || '%'
                     or exists (select 1 from files f where f.note_id = n.id
                                                       and f.name ilike '%' || v_text || '%')
              else true end)
       and (p_space is null or n.space = p_space)
       and (p_project is null or n.project = lower(p_project))
       and (p_since is null or n.created_at >= p_since)
       and (p_include_superseded or n.status = 'active')
     order by case when v_mode in ('fulltext', 'fulltext_any')
                   then greatest(ts_rank(n.fts, v_q),
                                 coalesce((select max(ts_rank(f.fts, v_q)) from files f
                                            where f.note_id = n.id), 0))
                   else 0 end desc,
              n.created_at desc
     limit v_lim
  ) s;

  return jsonb_build_object(
    'mode', v_mode,
    'total', v_total,
    'returned', jsonb_array_length(v_items),
    'truncated', v_total > jsonb_array_length(v_items),
    'items', v_items,
    'hint', 'memohub.get(id) returns the full note with its files'
  );
end;
$$;

-- Catalog: also reports storage usage and how to attach files.
create or replace function memohub.catalog()
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select jsonb_build_object(
    'tier', tier(),
    'private_spaces', to_jsonb(private_spaces()),
    'storage', storage_usage(),
    'spaces', (
      select coalesce(jsonb_agg(sp order by sp->>'slug'), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'slug', s.slug,
          'title', s.title,
          'inbox', (select count(*) from notes n
                     where n.space = s.slug and n.project is null and n.status = 'active'),
          'projects', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'slug', p.slug, 'title', p.title, 'aliases', p.aliases,
                     'notes', (select count(*) from notes n
                                where n.project = p.slug and n.status = 'active'))
                   order by p.slug)
            from projects p where p.space = s.slug), '[]'::jsonb)
        ) as sp
        from spaces s
      ) x),
    'tags', (
      select coalesce(jsonb_agg(jsonb_build_object('tag', tag, 'notes', cnt)
                                order by cnt desc, tag), '[]'::jsonb)
      from (select t as tag, count(*) as cnt
              from notes n, unnest(n.tags) t
             where n.status = 'active'
             group by t order by count(*) desc, t limit 50) t),
    'entities', (
      select coalesce(jsonb_agg(jsonb_build_object('type', type, 'name', name, 'notes', cnt)
                                order by cnt desc, name), '[]'::jsonb)
      from (select e->>'type' as type, min(e->>'name') as name, count(*) as cnt
              from notes n, jsonb_array_elements(n.entities) e
             where n.status = 'active'
             group by e->>'type', lower(e->>'name')
             order by count(*) desc, min(e->>'name') limit 50) e),
    'entity_types', to_jsonb(entity_types()),
    'hint', 'project = null means inbox; create projects only with the user''s consent via '
            || 'memohub.add_project. Reuse existing tags and entity names before creating new ones.'
            || case when tier() = 'private' then ''
                    else ' Spaces in private_spaces are stored only in memohub-private.' end,
    'files_hint', 'Files: memohub.check_upload(size_bytes, sha256) BEFORE uploading (refuses over quota, '
            || 'warns near it — tell the user), upload to bucket "files", then '
            || 'memohub.attach_file({note_id, path, name, summary, extracted_text, sha256}). '
            || 'Company documents: attach_file({note_id, url, name, summary}) — no upload.'
  );
$$;

revoke execute on all functions in schema memohub from public;
