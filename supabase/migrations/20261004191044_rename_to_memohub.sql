-- Rename the project to memohub: schema brain -> memohub.
-- Tables, indexes, RLS policies and grants move with the schema. Functions are re-pinned
-- to the new search_path; the ones whose bodies or hints name the schema are recreated.

alter schema brain rename to memohub;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'brain_backup') then
    alter role brain_backup rename to memohub_backup;
  end if;
end $$;

alter function memohub.add_project(text, text, text, text[]) set search_path = memohub, pg_catalog;
alter function memohub.get(uuid)                             set search_path = memohub, pg_catalog;
alter function memohub.tier()                                set search_path = memohub, pg_catalog;
alter function memohub.private_spaces()                      set search_path = memohub, pg_catalog;
alter function memohub.sensitive_findings(text)              set search_path = memohub, pg_catalog;

create or replace function memohub.save(p jsonb)
returns jsonb
language plpgsql
set search_path = memohub, pg_catalog
as $$
declare
  v_space      text := nullif(trim(p->>'space'), '');
  v_project    text := lower(nullif(trim(p->>'project'), ''));
  v_alias      text;
  v_supersedes uuid := nullif(p->>'supersedes', '')::uuid;
  v_entities   jsonb := coalesce(p->'entities', '[]'::jsonb);
  v_bad        jsonb;
  v_kinds      text[];
  v_id         uuid;
begin
  if v_space is null or not exists (select 1 from spaces where slug = v_space) then
    return jsonb_build_object('ok', false, 'error', 'unknown_space', 'got', v_space,
      'allowed', (select jsonb_agg(slug order by slug) from spaces));
  end if;

  if v_space = any (private_spaces()) and tier() <> 'private' then
    return jsonb_build_object('ok', false, 'error', 'private_space', 'space', v_space,
      'hint', 'This space is stored only in the private memohub (MCP server memohub-private). '
              || 'Save there, or ask the user.');
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
                || 'or create it via memohub.add_project.');
    end if;
    v_project := v_alias;
  end if;

  if nullif(trim(p->>'title'), '') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_title');
  end if;

  if jsonb_typeof(v_entities) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'entities_not_array');
  end if;
  select jsonb_agg(e) into v_bad
    from jsonb_array_elements(v_entities) e
   where jsonb_typeof(e) <> 'object'
      or not (e->>'type' = any (entity_types()))
      or nullif(trim(e->>'name'), '') is null;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'error', 'bad_entities', 'got', v_bad,
      'allowed_types', to_jsonb(entity_types()),
      'hint', 'Each entity is {"type": <allowed type>, "name": <non-empty>}.');
  end if;

  v_kinds := sensitive_findings(concat_ws(' ', p->>'title', p->>'body_md',
                                          p->>'decisions', p->>'open_questions',
                                          p->>'tags', v_entities::text));
  if cardinality(v_kinds) > 0 then
    return jsonb_build_object('ok', false, 'error', 'sensitive_data', 'kinds', to_jsonb(v_kinds),
      'hint', 'Remove or generalize these values (e.g. "карта Тинькофф", "паспорт продлён до 2031") '
              || 'and save again. Values are not echoed back.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('type', t, 'name', n) order by t, n), '[]'::jsonb)
    into v_entities
    from (select distinct on (e->>'type', lower(trim(e->>'name')))
                 e->>'type' as t, trim(e->>'name') as n
            from jsonb_array_elements(v_entities) e
           order by e->>'type', lower(trim(e->>'name'))) x;

  insert into notes (space, project, type, title, body_md, decisions, open_questions,
                     tags, entities, source, device, supersedes)
  values (
    v_space,
    v_project,
    coalesce(nullif(p->>'type', ''), 'session'),
    trim(p->>'title'),
    coalesce(p->>'body_md', ''),
    coalesce(p->'decisions', '[]'::jsonb),
    coalesce(p->'open_questions', '[]'::jsonb),
    coalesce(array(select distinct lower(trim(t))
                     from jsonb_array_elements_text(p->'tags') t
                    where trim(t) <> ''), '{}'),
    v_entities,
    coalesce(nullif(p->>'source', ''), 'manual'),
    nullif(p->>'device', ''),
    v_supersedes
  )
  returning id into v_id;

  if v_supersedes is not null then
    update notes set status = 'superseded', updated_at = now() where id = v_supersedes;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'space', v_space,
                            'project', v_project, 'inbox', v_project is null,
                            'tier', tier());
end;
$$;

create or replace function memohub.catalog()
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select jsonb_build_object(
    'tier', tier(),
    'private_spaces', to_jsonb(private_spaces()),
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
                    else ' Spaces in private_spaces are stored only in memohub-private.' end
  );
$$;

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
   where (v_q is null or n.fts @@ v_q)
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
       where n.fts @@ v_q
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
     where (n.title ilike '%' || v_text || '%' or n.body_md ilike '%' || v_text || '%')
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
               when v_mode in ('fulltext', 'fulltext_any')
                 then ts_headline('russian', n.body_md, v_q,
                                  'MaxWords=35, MinWords=12, MaxFragments=2')
               else left(n.body_md, 240) end
           ) as item
      from notes n
     where (case
              when v_mode in ('fulltext', 'fulltext_any') then n.fts @@ v_q
              when v_mode = 'substring' then n.title ilike '%' || v_text || '%'
                                          or n.body_md ilike '%' || v_text || '%'
              else true end)
       and (p_space is null or n.space = p_space)
       and (p_project is null or n.project = lower(p_project))
       and (p_since is null or n.created_at >= p_since)
       and (p_include_superseded or n.status = 'active')
     order by case when v_mode in ('fulltext', 'fulltext_any')
                   then ts_rank(n.fts, v_q) else 0 end desc,
              n.created_at desc
     limit v_lim
  ) s;

  return jsonb_build_object(
    'mode', v_mode,
    'total', v_total,
    'returned', jsonb_array_length(v_items),
    'truncated', v_total > jsonb_array_length(v_items),
    'items', v_items,
    'hint', 'memohub.get(id) returns the full note'
  );
end;
$$;

create or replace function memohub.recent(
  p_space text default null, p_project text default null, p_limit int default 10
)
returns jsonb
language sql stable
set search_path = memohub, pg_catalog
as $$
  select memohub.search(null, p_space, p_project, null, p_limit);
$$;

revoke execute on all functions in schema memohub from public;
