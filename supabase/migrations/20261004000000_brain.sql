-- Second brain: notes catalogued by space/project with Russian full-text search.
-- Lives in its own schema `brain`, which the Supabase Data API does not expose;
-- clients work only through the brain.* functions below.

create schema if not exists brain;

-- Catalog -------------------------------------------------------------------

create table brain.spaces (
  slug  text primary key,
  title text not null
);

insert into brain.spaces (slug, title) values
  ('work',     'Работа'),
  ('personal', 'Личное'),
  ('learning', 'Обучение'),
  ('medicine', 'Медицина'),
  ('travel',   'Путешествия');

create table brain.projects (
  -- Work projects are named after their git repo / local folder (agent_platform,
  -- my-site); slugs are stored lower-case.
  slug       text primary key check (slug ~ '^[a-z0-9][a-z0-9._-]{0,62}$'),
  space      text not null references brain.spaces (slug),
  title      text not null,
  aliases    text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (slug, space)
);

-- Notes ---------------------------------------------------------------------

create table brain.notes (
  id             uuid primary key default gen_random_uuid(),
  space          text not null references brain.spaces (slug),
  project        text,
  type           text not null default 'session'
                   check (type in ('session', 'decision', 'fact', 'note')),
  title          text not null check (length(title) between 1 and 200),
  body_md        text not null default '',
  decisions      jsonb not null default '[]' check (jsonb_typeof(decisions) = 'array'),
  open_questions jsonb not null default '[]' check (jsonb_typeof(open_questions) = 'array'),
  tags           text[] not null default '{}',
  source         text not null
                   check (source in ('claude', 'claude-code', 'chatgpt', 'codex', 'manual')),
  device         text,
  status         text not null default 'active'
                   check (status in ('active', 'superseded', 'archived')),
  supersedes     uuid references brain.notes (id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- A project must belong to the note's space; a NULL project means "inbox".
  foreign key (project, space) references brain.projects (slug, space),
  -- The 'russian' config stems Latin words with the English stemmer, so mixed
  -- RU/EN text is covered by one config.
  fts tsvector generated always as (
    setweight(to_tsvector('russian', title), 'A') ||
    setweight(to_tsvector('russian', decisions::text || ' ' || open_questions::text), 'B') ||
    setweight(to_tsvector('russian', body_md), 'C')
  ) stored
);

create index notes_fts_idx     on brain.notes using gin (fts);
create index notes_tags_idx    on brain.notes using gin (tags);
create index notes_catalog_idx on brain.notes (space, project, created_at desc);

-- Access --------------------------------------------------------------------
-- RLS on with no policies: only the owner (the connector's postgres role)
-- sees rows. Backup gets its own read policy, see supabase/manual/backup_role.sql.

alter table brain.spaces   enable row level security;
alter table brain.projects enable row level security;
alter table brain.notes    enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on schema brain from anon, authenticated;
    revoke all on all tables in schema brain from anon, authenticated;
  end if;
end $$;

-- Functions -----------------------------------------------------------------
-- Errors a model can fix are returned as {ok:false, error, ...} instead of raised,
-- so the caller sees what to ask the user.

create or replace function brain.catalog()
returns jsonb
language sql stable
set search_path = brain, pg_catalog
as $$
  select jsonb_build_object(
    'spaces', coalesce(jsonb_agg(sp order by sp->>'slug'), '[]'::jsonb),
    'hint', 'project = null means inbox; create projects only with the user''s consent via brain.add_project'
  )
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
  ) x;
$$;

create or replace function brain.add_project(
  p_slug text, p_space text, p_title text, p_aliases text[] default '{}'
)
returns jsonb
language plpgsql
set search_path = brain, pg_catalog
as $$
begin
  if not exists (select 1 from spaces where slug = p_space) then
    return jsonb_build_object('ok', false, 'error', 'unknown_space',
      'allowed', (select jsonb_agg(slug order by slug) from spaces));
  end if;
  if exists (select 1 from projects where slug = lower(trim(p_slug))) then
    return jsonb_build_object('ok', false, 'error', 'project_exists',
      'project', (select to_jsonb(p) from projects p where slug = lower(trim(p_slug))));
  end if;
  insert into projects (slug, space, title, aliases)
  values (lower(trim(p_slug)), p_space, p_title, coalesce(p_aliases, '{}'));
  return jsonb_build_object('ok', true, 'slug', lower(trim(p_slug)), 'space', p_space);
end;
$$;

create or replace function brain.save(p jsonb)
returns jsonb
language plpgsql
set search_path = brain, pg_catalog
as $$
declare
  v_space      text := nullif(trim(p->>'space'), '');
  v_project    text := lower(nullif(trim(p->>'project'), ''));
  v_alias      text;
  v_supersedes uuid := nullif(p->>'supersedes', '')::uuid;
  v_id         uuid;
begin
  if v_space is null or not exists (select 1 from spaces where slug = v_space) then
    return jsonb_build_object('ok', false, 'error', 'unknown_space', 'got', v_space,
      'allowed', (select jsonb_agg(slug order by slug) from spaces));
  end if;

  if v_project is not null
     and not exists (select 1 from projects where slug = v_project and space = v_space) then
    select slug into v_alias
      from projects
     where space = v_space
       and v_project = any (select lower(a) from unnest(aliases) a);
    if v_alias is null then
      return jsonb_build_object('ok', false, 'error', 'unknown_project',
        'got', v_project, 'space', v_space,
        'known', (select coalesce(jsonb_agg(slug order by slug), '[]'::jsonb)
                    from projects where space = v_space),
        'hint', 'Ask the user: pick a known project, save with project=null (inbox), '
                || 'or create it via brain.add_project.');
    end if;
    v_project := v_alias;
  end if;

  if nullif(trim(p->>'title'), '') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_title');
  end if;

  insert into notes (space, project, type, title, body_md, decisions, open_questions,
                     tags, source, device, supersedes)
  values (
    v_space,
    v_project,
    coalesce(nullif(p->>'type', ''), 'session'),
    trim(p->>'title'),
    coalesce(p->>'body_md', ''),
    coalesce(p->'decisions', '[]'::jsonb),
    coalesce(p->'open_questions', '[]'::jsonb),
    coalesce(array(select lower(jsonb_array_elements_text(p->'tags'))), '{}'),
    coalesce(nullif(p->>'source', ''), 'manual'),
    nullif(p->>'device', ''),
    v_supersedes
  )
  returning id into v_id;

  if v_supersedes is not null then
    update notes set status = 'superseded', updated_at = now() where id = v_supersedes;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'space', v_space,
                            'project', v_project, 'inbox', v_project is null);
end;
$$;

create or replace function brain.search(
  q                    text    default null,
  p_space              text    default null,
  p_project            text    default null,
  p_since              date    default null,
  p_limit              int     default 8,
  p_include_superseded boolean default false
)
returns jsonb
language plpgsql stable
set search_path = brain, pg_catalog
as $$
declare
  v_lim   int := least(greatest(coalesce(p_limit, 8), 1), 25);
  v_q     tsquery;
  v_mode  text := 'recent';
  v_total int;
  v_items jsonb;
begin
  if nullif(trim(q), '') is not null then
    v_q := websearch_to_tsquery('russian', q);
    v_mode := 'fulltext';
  end if;

  select count(*) into v_total
    from notes n
   where (v_q is null or n.fts @@ v_q)
     and (p_space is null or n.space = p_space)
     and (p_project is null or n.project = lower(p_project))
     and (p_since is null or n.created_at >= p_since)
     and (p_include_superseded or n.status = 'active');

  -- Names, codes and partial words the stemmer misses: fall back to substring.
  if v_total = 0 and v_q is not null then
    v_mode := 'substring';
    select count(*) into v_total
      from notes n
     where (n.title ilike '%' || trim(q) || '%' or n.body_md ilike '%' || trim(q) || '%')
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
             'snippet', case
               when v_mode = 'fulltext'
                 then ts_headline('russian', n.body_md, v_q,
                                  'MaxWords=35, MinWords=12, MaxFragments=2')
               else left(n.body_md, 240) end
           ) as item
      from notes n
     where (case v_mode
              when 'fulltext'  then n.fts @@ v_q
              when 'substring' then n.title ilike '%' || trim(q) || '%'
                                 or n.body_md ilike '%' || trim(q) || '%'
              else true end)
       and (p_space is null or n.space = p_space)
       and (p_project is null or n.project = lower(p_project))
       and (p_since is null or n.created_at >= p_since)
       and (p_include_superseded or n.status = 'active')
     order by case when v_mode = 'fulltext' then ts_rank(n.fts, v_q) else 0 end desc,
              n.created_at desc
     limit v_lim
  ) s;

  return jsonb_build_object(
    'mode', v_mode,
    'total', v_total,
    'returned', jsonb_array_length(v_items),
    'truncated', v_total > jsonb_array_length(v_items),
    'items', v_items,
    'hint', 'brain.get(id) returns the full note'
  );
end;
$$;

create or replace function brain.recent(
  p_space text default null, p_project text default null, p_limit int default 10
)
returns jsonb
language sql stable
set search_path = brain, pg_catalog
as $$
  select brain.search(null, p_space, p_project, null, p_limit);
$$;

create or replace function brain.get(p_id uuid)
returns jsonb
language sql stable
set search_path = brain, pg_catalog
as $$
  select coalesce(
    (select to_jsonb(n) - 'fts' from notes n where n.id = p_id),
    jsonb_build_object('ok', false, 'error', 'not_found', 'id', p_id)
  );
$$;

-- Functions are executable by PUBLIC by default; only the owner needs them.
revoke execute on all functions in schema brain from public;
