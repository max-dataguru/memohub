-- Entities on notes + tag reuse.
-- 1. notes.entities: [{type, name}] filled by the model on save. Nothing is built from it yet;
--    a future graph (entities / note_entities tables) is a projection of this column, so no
--    LLM re-run over history is needed.
-- 2. catalog() returns the most used tags and entities, so models reuse existing names
--    instead of inventing synonyms.

alter table brain.notes
  add column entities jsonb not null default '[]'
    check (jsonb_typeof(entities) = 'array');

-- Rebuild the generated search vector so entity names are searchable too.
drop index brain.notes_fts_idx;
alter table brain.notes drop column fts;
alter table brain.notes add column fts tsvector generated always as (
  setweight(to_tsvector('russian', title), 'A') ||
  setweight(to_tsvector('russian', decisions::text || ' ' || open_questions::text
                                   || ' ' || entities::text), 'B') ||
  setweight(to_tsvector('russian', body_md), 'C')
) stored;
create index notes_fts_idx on brain.notes using gin (fts);

create or replace function brain.entity_types()
returns text[]
language sql immutable
as $$ select array['person', 'org', 'tool', 'place', 'topic'] $$;

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
  v_entities   jsonb := coalesce(p->'entities', '[]'::jsonb);
  v_bad        jsonb;
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
  -- Keep only {type, name}, trimmed, de-duplicated case-insensitively.
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
                            'project', v_project, 'inbox', v_project is null);
end;
$$;

create or replace function brain.catalog()
returns jsonb
language sql stable
set search_path = brain, pg_catalog
as $$
  select jsonb_build_object(
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
    -- Top 50 by use: reuse these names before inventing new ones.
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
            || 'brain.add_project. Reuse existing tags and entity names before creating new ones.'
  );
$$;

revoke execute on all functions in schema brain from public;
